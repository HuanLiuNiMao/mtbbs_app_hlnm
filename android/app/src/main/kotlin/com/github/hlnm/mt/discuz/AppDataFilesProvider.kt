package com.github.hlnm.mt.discuz

import android.content.Context
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import android.system.ErrnoException
import android.system.Os
import android.system.StructStat
import android.webkit.MimeTypeMap
import java.io.File
import java.io.FileNotFoundException

/**
 * 应用私有目录的文件提供器（DocumentsProvider）。
 *
 * 用途：把本应用的私有目录通过系统 SAF 暴露出来，配合 MT 管理器 / 系统「文件」
 * 的「添加本地存储」，在**无需 ROOT** 的情况下浏览、修改应用数据
 * （数据库、Cookie、缓存、导出文件等），便于排查线上问题。
 *
 * 虚拟根下挂了四个入口（与 MT 的注入文件提供器保持一致，便于沿用同一套使用说明）：
 *
 * | 入口 | 实际路径 |
 * |---|---|
 * | `data` | `/data/user/0/<包名>`（应用私有目录，含 files/cache/databases/shared_prefs） |
 * | `android_data` | `/sdcard/Android/data/<包名>` |
 * | `android_obb` | `/sdcard/Android/obb/<包名>` |
 * | `user_de_data` | `/data/user_de/0/<包名>`（设备加密存储，存在时才挂） |
 *
 * 安全边界：provider 声明 `android.permission.MANAGE_DOCUMENTS`，这是 signature 级
 * 权限，只有系统（DocumentsUI / Settings）持有。第三方应用**不能**直接 query 本
 * provider，必须由用户在系统选择器里主动选中本应用后才能拿到 URI 授权——与
 * SAF 的标准模型一致，不存在"任意应用可读私有目录"的洞。
 *
 * 注意：provider 跑在本应用进程里，进程被系统回收后查询会失败；配合
 * [AppDataFilesWakeUpActivity]（空 Activity，仅用于把进程拉起来）使用。
 */
class AppDataFilesProvider : DocumentsProvider() {

    /** 虚拟根目录的 documentId 用包名，保证稳定（不随版本变化）。 */
    private lateinit var rootId: String

    /** 虚拟根下的四个入口，按固定顺序展示。 */
    private var mountPoints: List<MountPoint> = emptyList()

    private data class MountPoint(val segment: String, val dir: File)

    override fun attachInfo(context: Context, info: ProviderInfo?) {
        super.attachInfo(context, info)
        rootId = context.packageName
        mountPoints = buildList {
            // /data/user/0/<包名>：filesDir 的父目录
            context.filesDir?.parentFile?.let { add(MountPoint(SEG_DATA, it)) }
            // /sdcard/Android/data/<包名>：externalFilesDir 的父目录
            context.getExternalFilesDir(null)?.parentFile
                ?.takeIf { it.exists() }
                ?.let { add(MountPoint(SEG_ANDROID_DATA, it)) }
            // /sdcard/Android/obb/<包名>
            runCatching { context.obbDir }
                .getOrNull()
                ?.takeIf { it.exists() }
                ?.let { add(MountPoint(SEG_ANDROID_OBB, it)) }
            // /data/user_de/0/<包名>：设备加密存储，路径由 filesDir 推导
            userDeDirOf(context)
                ?.takeIf { it.exists() }
                ?.let { add(MountPoint(SEG_USER_DE_DATA, it)) }
        }
    }

    // ==================== 路径解析 ====================

    /**
     * documentId → File。
     *
     * @return null 表示虚拟根
     * @throws FileNotFoundException documentId 不属于本 provider / 路径不存在
     */
    private fun fileOf(documentId: String, mustExist: Boolean = true): File? {
        if (documentId == rootId) return null
        val prefix = "$rootId/"
        if (!documentId.startsWith(prefix)) {
            throw FileNotFoundException("$documentId not found")
        }
        val rest = documentId.substring(prefix.length)
        val slash = rest.indexOf('/')
        val segment = if (slash < 0) rest else rest.substring(0, slash)
        val subPath = if (slash < 0) "" else rest.substring(slash + 1)
        val base = mountPoints.firstOrNull { it.segment == segment }?.dir
            ?: throw FileNotFoundException("$documentId not found")
        val file = if (subPath.isEmpty()) base else File(base, subPath)
        if (mustExist && !existsNoFollow(file)) {
            throw FileNotFoundException("$documentId not found")
        }
        return file
    }

    /** documentId 里的子路径（用于拼子节点 id），虚拟根返回空串。 */
    private fun documentIdOf(parentId: String, name: String): String =
        if (parentId.endsWith("/")) parentId + name else "$parentId/$name"

    // ==================== Roots ====================

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val appInfo = context!!.applicationInfo
        val appLabel = context!!.packageManager.getApplicationLabel(appInfo).toString()
        val cursor = MatrixCursor(projection ?: DEFAULT_ROOT_PROJECTION)
        cursor.newRow().apply {
            putIfPresent(cursor, Root.COLUMN_ROOT_ID, rootId)
            putIfPresent(cursor, Root.COLUMN_DOCUMENT_ID, rootId)
            putIfPresent(cursor, Root.COLUMN_TITLE, appLabel)
            putIfPresent(cursor, Root.COLUMN_SUMMARY, rootId)
            putIfPresent(cursor, Root.COLUMN_ICON, appInfo.icon)
            putIfPresent(cursor, Root.COLUMN_MIME_TYPES, "*/*")
            putIfPresent(
                cursor,
                Root.COLUMN_FLAGS,
                Root.FLAG_SUPPORTS_CREATE or
                    Root.FLAG_SUPPORTS_IS_CHILD or
                    // 全部是本机数据，没有云端，标上 LOCAL_ONLY 让系统选择器不做网络相关处理
                    Root.FLAG_LOCAL_ONLY,
            )
        }
        return cursor
    }

    // ==================== 文档查询 ====================

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(projection ?: DEFAULT_DOCUMENT_PROJECTION)
        includeFile(cursor, documentId, fileOf(documentId, mustExist = false))
        return cursor
    }

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val cursor = MatrixCursor(projection ?: DEFAULT_DOCUMENT_PROJECTION)
        val parent = fileOf(parentDocumentId)
        if (parent == null) {
            // 虚拟根：只列出四个挂载点，不展示真实路径
            for (mp in mountPoints) {
                includeFile(cursor, documentIdOf(parentDocumentId, mp.segment), mp.dir)
            }
        } else {
            val children = parent.listFiles() ?: emptyArray()
            for (child in children.sortedBy { it.name.lowercase() }) {
                includeFile(cursor, documentIdOf(parentDocumentId, child.name), child)
            }
        }
        return cursor
    }

    override fun getDocumentType(documentId: String): String {
        val file = fileOf(documentId) ?: return Document.MIME_TYPE_DIR
        return mimeTypeOf(file)
    }

    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean {
        if (parentDocumentId == documentId) return false
        if (parentDocumentId == rootId) return documentId.startsWith("$rootId/")
        return documentId.startsWith("$parentDocumentId/")
    }

    // ==================== 文件读写 ====================

    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?,
    ): ParcelFileDescriptor {
        val file = fileOf(documentId, mustExist = false)
            ?: throw FileNotFoundException("$documentId not found")
        return ParcelFileDescriptor.open(file, parcelMode(mode))
    }

    override fun createDocument(
        parentDocumentId: String,
        mimeType: String,
        displayName: String,
    ): String {
        val parent = fileOf(parentDocumentId)
            ?: throw FileNotFoundException("cannot create in root")
        // 重名时追加 (2) (3)…，与系统文件管理器的心智模型一致
        var target = File(parent, displayName)
        var seq = 2
        while (target.exists()) {
            target = File(parent, "$displayName ($seq)")
            seq++
        }
        val created =
            if (Document.MIME_TYPE_DIR == mimeType) target.mkdir() else target.createNewFile()
        if (!created) {
            throw FileNotFoundException("failed to create $displayName in $parentDocumentId")
        }
        return documentIdOf(parentDocumentId, target.name)
    }

    override fun deleteDocument(documentId: String) {
        val file = fileOf(documentId) ?: throw FileNotFoundException("cannot delete root")
        if (!deleteRecursively(file)) {
            throw FileNotFoundException("failed to delete $documentId")
        }
    }

    override fun removeDocument(documentId: String, parentDocumentId: String) =
        deleteDocument(documentId)

    override fun renameDocument(documentId: String, displayName: String): String {
        val file = fileOf(documentId) ?: throw FileNotFoundException("cannot rename root")
        val parent = file.parentFile
            ?: throw FileNotFoundException("$documentId has no parent")
        val target = File(parent, displayName)
        if (!file.renameTo(target)) {
            throw FileNotFoundException("failed to rename $documentId to $displayName")
        }
        val parentId = documentId.substringBeforeLast('/', "")
        return if (parentId.isEmpty()) displayName else "$parentId/$displayName"
    }

    override fun moveDocument(
        sourceDocumentId: String,
        sourceParentDocumentId: String,
        targetParentDocumentId: String,
    ): String {
        val source = fileOf(sourceDocumentId) ?: throw FileNotFoundException("cannot move root")
        val targetDir = fileOf(targetParentDocumentId)
            ?: throw FileNotFoundException("cannot move into root")
        val target = File(targetDir, source.name)
        if (target.exists() || !source.renameTo(target)) {
            throw FileNotFoundException("failed to move $sourceDocumentId")
        }
        return documentIdOf(targetParentDocumentId, target.name)
    }

    // ==================== MT 扩展方法 ====================

    /**
     * MT 管理器的私有扩展（`mt:` 前缀）：改时间戳 / 改权限 / 建软链接。
     *
     * 这些不是系统 API，只有 MT 会调用；其它客户端拿不到也不会用，
     * 不实现则 MT 里对应菜单灰掉或报错。协议常量沿用 MT 的定义。
     */
    override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
        super.call(method, arg, extras)?.let { return it }
        if (!method.startsWith(MT_METHOD_PREFIX)) return null

        val out = Bundle()
        try {
            val uri = extras?.let { extrasOf(it) } ?: throw IllegalArgumentException("no uri")
            val documentId = try {
                DocumentsContract.getDocumentId(uri)
            } catch (_: Exception) {
                // 非标准 URI 时退化为取路径片段（MT 部分版本就是这么传的）
                val segments = uri.pathSegments
                if (segments.size >= 4) segments[3] else segments.getOrElse(1) { "" }
            }
            val file = fileOf(
                documentId,
                mustExist = method != MT_METHOD_CREATE_SYMLINK,
            ) ?: throw FileNotFoundException("$documentId not found")
            when (method) {
                MT_METHOD_SET_LAST_MODIFIED -> {
                    val time = extras.getLong("time")
                    out.putBoolean("result", file.setLastModified(time))
                }
                MT_METHOD_SET_PERMISSIONS -> {
                    val permissions = extras.getInt("permissions")
                    try {
                        Os.chmod(file.path, permissions)
                        out.putBoolean("result", true)
                    } catch (e: ErrnoException) {
                        out.putBoolean("result", false)
                        out.putString("message", e.message)
                    }
                }
                MT_METHOD_CREATE_SYMLINK -> {
                    val path = extras.getString("path")
                    try {
                        Os.symlink(path, file.path)
                        out.putBoolean("result", true)
                    } catch (e: ErrnoException) {
                        out.putBoolean("result", false)
                        out.putString("message", e.message)
                    }
                }
                else -> {
                    out.putBoolean("result", false)
                    out.putString("message", "unsupported method: $method")
                }
            }
        } catch (e: Exception) {
            out.putBoolean("result", false)
            out.putString("message", e.toString())
        }
        return out
    }

    override fun onCreate(): Boolean = true

    // ==================== 行构造 ====================

    /**
     * 往 cursor 里填一行文档信息。
     *
     * [file] 为 null 表示虚拟根本身（MT/系统需要能 query 到根 document）。
     */
    private fun includeFile(cursor: MatrixCursor, documentId: String, file: File?) {
        if (file == null) {
            cursor.newRow().apply {
                putIfPresent(cursor, Document.COLUMN_DOCUMENT_ID, rootId)
                putIfPresent(cursor, Document.COLUMN_DISPLAY_NAME, rootId)
                putIfPresent(cursor, Document.COLUMN_MIME_TYPE, Document.MIME_TYPE_DIR)
                putIfPresent(cursor, Document.COLUMN_SIZE, 0L)
                putIfPresent(cursor, Document.COLUMN_LAST_MODIFIED, 0L)
                putIfPresent(cursor, Document.COLUMN_FLAGS, 0)
            }
            return
        }

        val isDir = file.isDirectory
        var flags = 0
        if (isDir) {
            if (file.canWrite()) flags = flags or Document.FLAG_DIR_SUPPORTS_CREATE
        } else {
            if (file.canWrite()) flags = flags or Document.FLAG_SUPPORTS_WRITE
        }
        val parentWritable = file.parentFile?.canWrite() == true
        if (parentWritable) {
            // 与系统「文件」的心智模型一致：父目录可写就能删/改名/移动。
            // 不加 MOVE/REMOVE 时 MT 的「移动」「移除」菜单是灰的。
            flags = flags or
                Document.FLAG_SUPPORTS_DELETE or
                Document.FLAG_SUPPORTS_RENAME or
                Document.FLAG_SUPPORTS_MOVE or
                Document.FLAG_SUPPORTS_REMOVE
        }

        cursor.newRow().apply {
            putIfPresent(cursor, Document.COLUMN_DOCUMENT_ID, documentId)
            putIfPresent(cursor, Document.COLUMN_DISPLAY_NAME, displayNameOf(file))
            putIfPresent(cursor, Document.COLUMN_MIME_TYPE, mimeTypeOf(file))
            putIfPresent(cursor, Document.COLUMN_SIZE, if (isDir) 0L else file.length())
            putIfPresent(cursor, Document.COLUMN_LAST_MODIFIED, file.lastModified())
            putIfPresent(cursor, Document.COLUMN_FLAGS, flags)
            putIfPresent(cursor, COLUMN_MT_PATH, file.absolutePath)
            putIfPresent(cursor, COLUMN_MT_EXTRAS, statSummary(file))
        }
    }

    /**
     * 四个挂载点用入口名展示（`data` 等），其余用文件名。
     *
     * 不能统一用 `file.name`：这些目录的真实名字就是包名，列出来全是同一个名字，
     * 用户无法区分 /data 与 Android/data。
     */
    private fun displayNameOf(file: File): String =
        mountPoints.firstOrNull { it.dir.absolutePath == file.absolutePath }?.segment
            ?: file.name

    /**
     * MT 的 `mt_extras` 列：`mode|uid|gid[|symlink target]`。
     *
     * 十进制 mode 与 uid/gid 让 MT 能显示「权限 / 所有者」，是否软链接由 mode
     * 的高 4 位判断。取不到就不填，MT 显示为空而不是崩。
     */
    private fun statSummary(file: File): String? = try {
        val stat: StructStat = Os.lstat(file.path)
        buildString {
            append(stat.st_mode).append('|').append(stat.st_uid).append('|').append(stat.st_gid)
            if (stat.st_mode and S_IFMT == S_IFLNK) {
                append('|').append(Os.readlink(file.path))
            }
        }
    } catch (_: Exception) {
        null
    }

    private fun mimeTypeOf(file: File): String {
        if (file.isDirectory) return Document.MIME_TYPE_DIR
        val ext = file.name.substringAfterLast('.', "").lowercase()
        if (ext.isNotEmpty()) {
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)?.let { return it }
        }
        return "application/octet-stream"
    }

    // ==================== 系统调用辅助 ====================

    /**
     * 从 Bundle 取 MT 传进来的目标 URI。
     *
     * `Bundle.getParcelable(String)` 在 API 33 起被标记弃用（新增了带 ClassLoader 的
     * 重载）。这里仍走旧重载：新重载在 API 33 以下不存在，minSdk 覆盖到低版本时
     * 直接调用会 NoSuchMethodError。`@Suppress("DEPRECATION")` 是刻意的，不要"顺手修掉"。
     */
    @Suppress("DEPRECATION")
    private fun extrasOf(extras: Bundle): Uri? =
        extras.getParcelable<Uri>("uri")

    /** MatrixCursor 只接受投影里存在的列，缺列时直接跳过（否则抛 IllegalArgumentException）。 */
    private fun MatrixCursor.RowBuilder.putIfPresent(
        cursor: MatrixCursor,
        column: String,
        value: Any?,
    ) {
        if (cursor.columnNames.contains(column)) add(column, value)
    }

    private fun parcelMode(mode: String): Int = when (mode) {
        "r" -> ParcelFileDescriptor.MODE_READ_ONLY
        "w", "wt" -> ParcelFileDescriptor.MODE_WRITE_ONLY or
            ParcelFileDescriptor.MODE_CREATE or
            ParcelFileDescriptor.MODE_TRUNCATE
        "wa" -> ParcelFileDescriptor.MODE_WRITE_ONLY or
            ParcelFileDescriptor.MODE_CREATE or
            ParcelFileDescriptor.MODE_APPEND
        "rw" -> ParcelFileDescriptor.MODE_READ_WRITE or ParcelFileDescriptor.MODE_CREATE
        "rwt" -> ParcelFileDescriptor.MODE_READ_WRITE or
            ParcelFileDescriptor.MODE_CREATE or
            ParcelFileDescriptor.MODE_TRUNCATE
        else -> throw IllegalArgumentException("invalid mode: $mode")
    }

    /**
     * 用 lstat 判断存在性，而不是 [File.exists]。
     *
     * 软链接指向不可访问的目标时 `exists()` 返回 false，会把链接整个藏掉；
     * 但应用目录里（cache 清理残留、用户手动建的链接）确实会有这种链接。
     */
    private fun existsNoFollow(file: File): Boolean = try {
        Os.lstat(file.path)
        true
    } catch (_: Exception) {
        false
    }

    /** 递归删除，软链接只删链接本身、不跟进去删目标。 */
    private fun deleteRecursively(file: File): Boolean {
        if (file.isDirectory && !isSymlink(file)) {
            file.listFiles()?.forEach { child ->
                if (!deleteRecursively(child)) return false
            }
        }
        return file.delete()
    }

    private fun isSymlink(file: File): Boolean = try {
        Os.lstat(file.path).st_mode and S_IFMT == S_IFLNK
    } catch (_: Exception) {
        false
    }

    companion object {
        private const val SEG_DATA = "data"
        private const val SEG_ANDROID_DATA = "android_data"
        private const val SEG_ANDROID_OBB = "android_obb"
        private const val SEG_USER_DE_DATA = "user_de_data"

        /** MT 的私有扩展列/方法名（沿用其协议常量，否则 MT 侧功能不可用）。 */
        private const val COLUMN_MT_EXTRAS = "mt_extras"
        private const val COLUMN_MT_PATH = "mt_path"
        private const val MT_METHOD_PREFIX = "mt:"
        private const val MT_METHOD_SET_LAST_MODIFIED = "mt:setLastModified"
        private const val MT_METHOD_SET_PERMISSIONS = "mt:setPermissions"
        private const val MT_METHOD_CREATE_SYMLINK = "mt:createSymlink"

        private const val S_IFMT = 0xF000
        private const val S_IFLNK = 0xA000

        private val DEFAULT_ROOT_PROJECTION = arrayOf(
            Root.COLUMN_ROOT_ID,
            Root.COLUMN_DOCUMENT_ID,
            Root.COLUMN_TITLE,
            Root.COLUMN_SUMMARY,
            Root.COLUMN_ICON,
            Root.COLUMN_MIME_TYPES,
            Root.COLUMN_FLAGS,
        )

        private val DEFAULT_DOCUMENT_PROJECTION = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_SIZE,
            Document.COLUMN_LAST_MODIFIED,
            Document.COLUMN_FLAGS,
            COLUMN_MT_PATH,
            COLUMN_MT_EXTRAS,
        )

        /** `/data/user/0/<包名>` → `/data/user_de/0/<包名>`；路径不匹配时返回 null。 */
        private fun userDeDirOf(context: Context): File? {
            val path = context.filesDir?.parentFile?.path ?: return null
            val prefix = "/data/user/"
            if (!path.startsWith(prefix)) return null
            return File("/data/user_de/" + path.substring(prefix.length))
        }
    }
}
