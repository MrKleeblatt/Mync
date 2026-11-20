package com.github.mrkleeblatt.mync

import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import java.util.concurrent.Executors

/**
 * Kanal „mync/fs“: Zugriff auf die Musikordner über die Ordnerfreigabe
 * (Storage Access Framework). mync sieht nur die Ordner, die der Nutzer
 * ausgewählt hat – kein „Zugriff auf alle Dateien“.
 *
 * Ein Ort besteht aus der Freigabe (`tree`, eine content://…/tree/…-URI)
 * und einem Pfad darin (`rel`, mit `/`, leer = der freigegebene Ordner).
 * Alles außer der Ordnerauswahl läuft in einem Hintergrund-Thread.
 */
class MusicFs(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val io = Executors.newFixedThreadPool(2)
    private val main = Handler(Looper.getMainLooper())
    private val resolver: ContentResolver get() = activity.contentResolver
    private var pending: MethodChannel.Result? = null
    private var pendingSave: ByteArray? = null

    companion object {
        const val PICK_TREE = 4711
        const val SAVE_DOC = 4712
        private val columns = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_SIZE,
            Document.COLUMN_LAST_MODIFIED,
        )
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickTree" -> pickTree(call.argument<String>("initial"), result)
            "saveDocument" -> saveDocument(
                call.argument<String>("name")!!,
                call.argument<String>("mime") ?: "application/octet-stream",
                call.argument<ByteArray>("data")!!,
                result,
            )
            else -> io.execute {
                try {
                    val r = handle(call)
                    main.post { result.success(r) }
                } catch (e: FileNotFoundException) {
                    main.post { result.error("not_found", e.message, null) }
                } catch (e: SecurityException) {
                    main.post { result.error("no_access", e.message, null) }
                } catch (e: Exception) {
                    main.post { result.error("failed", "${e.javaClass.simpleName}: ${e.message}", null) }
                }
            }
        }
    }

    private fun handle(call: MethodCall): Any? {
        val tree = call.argument<String>("tree")?.let(Uri::parse)
        val rel = call.argument<String>("rel") ?: ""
        return when (call.method) {
            "persisted" -> resolver.persistedUriPermissions.map { it.uri.toString() }
            "release" -> {
                resolver.releasePersistableUriPermission(
                    tree!!,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
                null
            }
            "stat" -> stat(tree!!, rel)
            "children" -> children(tree!!, resolve(tree, rel)).map {
                mapOf("name" to it.name, "dir" to it.dir, "size" to it.size, "mtime" to it.mtime)
            }
            "listFiles" -> listFiles(tree!!)
            "read" -> resolver.openInputStream(uri(tree!!, resolve(tree, rel)))!!.use { it.readBytes() }
            "write" -> {
                val data = call.argument<ByteArray>("data")!!
                resolver.openOutputStream(createOrTruncate(tree!!, rel), "wt")!!.use { it.write(data) }
                null
            }
            "copyOut" -> {
                val dst = File(call.argument<String>("path")!!)
                dst.parentFile?.mkdirs()
                resolver.openInputStream(uri(tree!!, resolve(tree, rel)))!!.use { inp ->
                    dst.outputStream().use { inp.copyTo(it, 256 * 1024) }
                }
                null
            }
            "copyIn" -> {
                val src = File(call.argument<String>("path")!!)
                resolver.openOutputStream(createOrTruncate(tree!!, rel), "wt")!!.use { out ->
                    src.inputStream().use { it.copyTo(out, 256 * 1024) }
                }
                null
            }
            "openFds" -> {
                val mode = call.argument<String>("mode") ?: "r"
                call.argument<List<String>>("rels")!!.map { r ->
                    try {
                        resolver.openFileDescriptor(uri(tree!!, resolve(tree, r)), mode)!!.detachFd()
                    } catch (e: Exception) {
                        -1
                    }
                }
            }
            "closeFds" -> {
                for (fd in call.argument<List<Int>>("fds")!!) {
                    if (fd >= 0) try { ParcelFileDescriptor.adoptFd(fd).close() } catch (e: Exception) {}
                }
                null
            }
            "rename" -> {
                rename(tree!!, rel, call.argument<String>("to")!!)
                null
            }
            "delete" -> {
                DocumentsContract.deleteDocument(resolver, uri(tree!!, resolve(tree, rel)))
                null
            }
            "mkdirs" -> {
                ensureDir(tree!!, rel)
                null
            }
            "documentUri" -> uri(tree!!, resolve(tree, rel)).toString()
            else -> throw UnsupportedOperationException(call.method)
        }
    }

    // ─── Ordner wählen ────────────────────────────────────────────────────

    private fun pickTree(initial: String?, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("busy", "Auswahl läuft schon", null)
            return
        }
        pending = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
            )
            if (initial != null) putExtra(DocumentsContract.EXTRA_INITIAL_URI, Uri.parse(initial))
        }
        activity.startActivityForResult(intent, PICK_TREE)
    }

    private fun saveDocument(name: String, mime: String, data: ByteArray, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("busy", "Auswahl läuft schon", null)
            return
        }
        pending = result
        pendingSave = data
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mime
            putExtra(Intent.EXTRA_TITLE, name)
        }
        activity.startActivityForResult(intent, SAVE_DOC)
    }

    /** Aus MainActivity.onActivityResult; true, wenn es unsere Anfrage war. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_TREE && requestCode != SAVE_DOC) return false
        val result = pending ?: return true
        pending = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pendingSave = null
            result.success(null)
            return true
        }
        if (requestCode == PICK_TREE) {
            try {
                resolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
            } catch (e: SecurityException) {
                // ohne Schreibrecht: wenigstens lesen
                resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            result.success(uri.toString())
        } else {
            val bytes = pendingSave
            pendingSave = null
            io.execute {
                try {
                    resolver.openOutputStream(uri, "wt")!!.use { it.write(bytes) }
                    main.post { result.success(uri.toString()) }
                } catch (e: Exception) {
                    main.post { result.error("failed", e.message, null) }
                }
            }
        }
        return true
    }

    // ─── Dokumente ────────────────────────────────────────────────────────

    private data class Child(val id: String, val name: String, val dir: Boolean, val size: Long, val mtime: Long)

    private fun uri(tree: Uri, docId: String): Uri = DocumentsContract.buildDocumentUriUsingTree(tree, docId)

    private fun Cursor.child() = Child(
        id = getString(0),
        name = getString(1) ?: "",
        dir = getString(2) == Document.MIME_TYPE_DIR,
        size = if (isNull(3)) 0 else getLong(3),
        mtime = if (isNull(4)) 0 else getLong(4),
    )

    private fun children(tree: Uri, docId: String): List<Child> {
        val out = ArrayList<Child>()
        resolver.query(
            DocumentsContract.buildChildDocumentsUriUsingTree(tree, docId),
            columns, null, null, null,
        )?.use { c -> while (c.moveToNext()) out.add(c.child()) }
        return out
    }

    private fun query(tree: Uri, docId: String): Child? = try {
        resolver.query(uri(tree, docId), columns, null, null, null)?.use { c ->
            if (c.moveToFirst()) c.child() else null
        }
    } catch (e: FileNotFoundException) {
        null
    } catch (e: IllegalArgumentException) {
        null
    }

    /**
     * Dokument-ID zu einem Pfad in der Freigabe. Beim Gerätespeicher und
     * bei SD-Karten ist die ID der Pfad selbst („primary:Music/A/x.mp3“) –
     * das geht ohne Suche; sonst Ordner für Ordner nach dem Namen.
     */
    private fun resolve(tree: Uri, rel: String): String {
        val root = DocumentsContract.getTreeDocumentId(tree)
        if (rel.isEmpty()) return root
        if (tree.authority == "com.android.externalstorage.documents") {
            val id = if (root.endsWith(":")) root + rel else "$root/$rel"
            if (query(tree, id) != null) return id
            throw FileNotFoundException(rel)
        }
        var id = root
        for (part in rel.split('/')) {
            id = children(tree, id).firstOrNull { it.name == part }?.id ?: throw FileNotFoundException(rel)
        }
        return id
    }

    private fun stat(tree: Uri, rel: String): Map<String, Any>? {
        val id = try { resolve(tree, rel) } catch (e: FileNotFoundException) { return null }
        val c = query(tree, id) ?: return null
        return mapOf("dir" to c.dir, "size" to c.size, "mtime" to c.mtime)
    }

    /** Alle Dateien unter der Freigabe (ohne versteckte Ordner wie .mync-trash). */
    private fun listFiles(tree: Uri): List<Map<String, Any>> {
        val out = ArrayList<Map<String, Any>>()
        val todo = ArrayDeque<Pair<String, String>>()
        todo.add(DocumentsContract.getTreeDocumentId(tree) to "")
        while (todo.isNotEmpty()) {
            val (id, prefix) = todo.removeFirst()
            for (c in children(tree, id)) {
                val rel = if (prefix.isEmpty()) c.name else "$prefix/${c.name}"
                if (c.dir) {
                    if (!c.name.startsWith(".")) todo.add(c.id to rel)
                } else {
                    out.add(mapOf("path" to rel, "size" to c.size, "mtime_ns" to c.mtime * 1_000_000))
                }
            }
        }
        return out
    }

    private fun ensureDir(tree: Uri, rel: String): String {
        var id = DocumentsContract.getTreeDocumentId(tree)
        if (rel.isEmpty()) return id
        for (part in rel.split('/')) {
            val next = children(tree, id).firstOrNull { it.name == part }
            id = when {
                next == null -> DocumentsContract.getDocumentId(
                    DocumentsContract.createDocument(resolver, uri(tree, id), Document.MIME_TYPE_DIR, part)!!,
                )
                next.dir -> next.id
                else -> throw IllegalStateException("$part ist kein Ordner")
            }
        }
        return id
    }

    private fun mimeOf(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
    }

    /** URI zum Schreiben: vorhandene Datei, sonst neu angelegt (mit Ordnern). */
    private fun createOrTruncate(tree: Uri, rel: String): Uri {
        try {
            return uri(tree, resolve(tree, rel))
        } catch (e: FileNotFoundException) {}
        val dir = rel.substringBeforeLast('/', "")
        val name = rel.substringAfterLast('/')
        val parent = ensureDir(tree, dir)
        return DocumentsContract.createDocument(resolver, uri(tree, parent), mimeOf(name), name)
            ?: throw IllegalStateException("$rel konnte nicht angelegt werden")
    }

    private fun rename(tree: Uri, from: String, to: String) {
        if (from == to) return
        val target = try { resolve(tree, to) } catch (e: FileNotFoundException) { null }
        // nur Groß-/Kleinschreibung geändert: dieselbe Datei
        if (target != null && !from.equals(to, ignoreCase = true)) {
            throw IllegalStateException("Ziel existiert schon: $to")
        }
        val fromDir = from.substringBeforeLast('/', "")
        val toDir = to.substringBeforeLast('/', "")
        val toName = to.substringAfterLast('/')
        var doc = uri(tree, resolve(tree, from))
        if (fromDir != toDir) {
            val src = uri(tree, resolve(tree, fromDir))
            val dst = uri(tree, ensureDir(tree, toDir))
            doc = DocumentsContract.moveDocument(resolver, doc, src, dst)
                ?: throw IllegalStateException("Verschieben fehlgeschlagen: $from")
        }
        if (from.substringAfterLast('/') != toName) {
            DocumentsContract.renameDocument(resolver, doc, toName)
                ?: throw IllegalStateException("Umbenennen fehlgeschlagen: $from")
        }
    }
}
