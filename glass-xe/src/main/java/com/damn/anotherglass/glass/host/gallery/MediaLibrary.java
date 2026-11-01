package com.damn.anotherglass.glass.host.gallery;

import android.content.ContentResolver;
import android.content.Context;
import android.database.Cursor;
import android.database.ContentObserver;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.provider.MediaStore;

import com.damn.anotherglass.shared.gallery.MediaLibraryAPI;
import com.damn.anotherglass.shared.gallery.MediaLibraryItem;
import com.damn.anotherglass.shared.gallery.MediaLibraryRequest;
import com.damn.anotherglass.shared.gallery.MediaLibraryResponse;
import com.damn.anotherglass.shared.rpc.RPCMessage;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.util.ArrayList;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/** Read-only camera-roll access. No HTTP server or caller-supplied filesystem paths. */
public final class MediaLibrary {
    public interface Sender { void send(RPCMessage message); }

    private static final int MAX_CHUNK_BYTES = 96 * 1024;
    private static final String[] COLUMNS = {
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.DATA,
            MediaStore.Files.FileColumns.MIME_TYPE,
            MediaStore.Files.FileColumns.MEDIA_TYPE
    };
    private final ContentResolver resolver;
    private final Sender sender;
    private final ThreadPoolExecutor worker = new ThreadPoolExecutor(
            1, 1, 0, TimeUnit.MILLISECONDS, new ArrayBlockingQueue<>(16));
    private final AtomicInteger generation = new AtomicInteger();
    private final Handler handler = new Handler(Looper.getMainLooper());
    private volatile boolean connected;
    private final Runnable changed = this::notifyChanged;
    private final ContentObserver observer = new ContentObserver(handler) {
        @Override public void onChange(boolean selfChange) {
            handler.removeCallbacks(changed);
            handler.postDelayed(changed, 600);
        }
    };

    public MediaLibrary(Context context, Sender sender) {
        resolver = context.getApplicationContext().getContentResolver();
        this.sender = sender;
        try {
            resolver.registerContentObserver(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, observer);
            resolver.registerContentObserver(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true, observer);
        } catch (SecurityException ignored) {
            // List/Read still return a useful permission error; other companion features keep working.
        }
    }

    public void handle(MediaLibraryRequest request) {
        if (request == null || request.requestId == null || request.requestId.length() > 64) return;
        final int epoch = generation.get();
        try {
            worker.execute(() -> {
                if (epoch != generation.get()) return;
                MediaLibraryResponse response = responseFor(request);
                try {
                    if ("List".equals(request.operation)) list(request, response);
                    else if ("Thumbnail".equals(request.operation)) thumbnail(request, response);
                    else if ("Read".equals(request.operation)) read(request, response);
                    else throw new LibraryException("Unknown media operation. Update both companion apps.");
                } catch (SecurityException e) {
                    response.error = "Glass storage access is denied. Reinstall the updated Explorer APK with storage access.";
                } catch (Exception e) {
                    // Never include local paths or raw provider exception messages in RPC errors.
                    response.error = e instanceof LibraryException ? e.getMessage() : "Could not read this media item on Glass.";
                }
                if (epoch == generation.get()) sender.send(new RPCMessage(MediaLibraryAPI.ID, response));
            });
        } catch (RejectedExecutionException e) {
            MediaLibraryResponse response = responseFor(request);
            response.error = "Glass is busy. Try again in a moment.";
            sender.send(new RPCMessage(MediaLibraryAPI.ID, response));
        }
    }

    public void invalidateRequests() {
        generation.incrementAndGet();
        worker.getQueue().clear();
    }

    public void setConnected(boolean value) {
        connected = value;
        invalidateRequests();
    }

    private void notifyChanged() {
        if (!connected) return;
        MediaLibraryResponse response = new MediaLibraryResponse();
        response.requestId = "";
        response.operation = "Changed";
        sender.send(new RPCMessage(MediaLibraryAPI.ID, response));
    }

    public void close() {
        connected = false;
        handler.removeCallbacks(changed);
        resolver.unregisterContentObserver(observer);
        invalidateRequests();
        worker.shutdownNow();
    }

    private static MediaLibraryResponse responseFor(MediaLibraryRequest request) {
        MediaLibraryResponse response = new MediaLibraryResponse();
        response.requestId = request.requestId;
        response.operation = request.operation;
        response.mediaId = request.mediaId;
        return response;
    }

    private void list(MediaLibraryRequest request, MediaLibraryResponse response) throws IOException {
        int pageSize = Math.max(1, Math.min(request.pageSize, 48));
        String selection = "(" + MediaStore.Files.FileColumns.MEDIA_TYPE + "=? OR "
                + MediaStore.Files.FileColumns.MEDIA_TYPE + "=?)";
        String[] args = { String.valueOf(MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE),
                String.valueOf(MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO) };
        if (request.beforeId != null) {
            long before = numericId(request.beforeId);
            selection += " AND " + MediaStore.Files.FileColumns._ID + "<?";
            args = new String[]{args[0], args[1], String.valueOf(before)};
        }
        response.items = new ArrayList<>();
        try (Cursor cursor = resolver.query(MediaStore.Files.getContentUri("external"), COLUMNS,
                selection, args, MediaStore.Files.FileColumns._ID + " DESC")) {
            if (cursor == null) throw new LibraryException("The Glass media index is unavailable.");
            while (cursor.moveToNext()) {
                File file = indexedMediaFile(cursor.getString(1));
                if (file == null || file.length() <= 0) continue;
                if (response.items.size() == pageSize) { response.hasMore = true; break; }
                response.items.add(item(cursor, file));
            }
        }
        if (response.hasMore && !response.items.isEmpty()) {
            response.nextBeforeId = response.items.get(response.items.size() - 1).id;
        }
    }

    private void thumbnail(MediaLibraryRequest request, MediaLibraryResponse response) throws IOException {
        Resolved media = resolve(request);
        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inSampleSize = 2;
        Bitmap bitmap;
        long id = numericId(request.mediaId);
        if ("Video".equals(media.item.kind)) {
            bitmap = MediaStore.Video.Thumbnails.getThumbnail(resolver, id,
                    MediaStore.Video.Thumbnails.MINI_KIND, options);
        } else {
            bitmap = MediaStore.Images.Thumbnails.getThumbnail(resolver, id,
                    MediaStore.Images.Thumbnails.MINI_KIND, options);
        }
        if (bitmap == null) throw new LibraryException("Glass could not create a thumbnail for this item.");
        try {
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 65, bytes)) {
                throw new LibraryException("Glass could not encode the thumbnail.");
            }
            if (bytes.size() > 160 * 1024) throw new LibraryException("The thumbnail is too large.");
            response.data = bytes.toByteArray();
        } finally { bitmap.recycle(); }
    }

    private void read(MediaLibraryRequest request, MediaLibraryResponse response) throws IOException {
        Resolved media = resolve(request);
        long size = media.file.length();
        if (request.offset < 0 || request.offset >= size) throw new LibraryException("Invalid media offset. Refresh the gallery.");
        int count = (int) Math.min(Math.max(1, Math.min(request.length, MAX_CHUNK_BYTES)), size - request.offset);
        byte[] data = new byte[count];
        try (RandomAccessFile file = new RandomAccessFile(media.file, "r")) {
            file.seek(request.offset);
            file.readFully(data);
        }
        if (!revision(media.file).equals(request.revision)) throw new LibraryException("This item changed on Glass. Refresh the gallery.");
        response.offset = request.offset;
        response.totalBytes = size;
        response.data = data;
    }

    private Resolved resolve(MediaLibraryRequest request) throws IOException {
        long id = numericId(request.mediaId);
        try (Cursor cursor = resolver.query(MediaStore.Files.getContentUri("external"), COLUMNS,
                MediaStore.Files.FileColumns._ID + "=?", new String[]{String.valueOf(id)}, null)) {
            if (cursor != null && cursor.moveToFirst()) {
                int type = cursor.getInt(3);
                if (type != MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE && type != MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO) {
                    throw new LibraryException("This is not a photo or video.");
                }
                File file = indexedMediaFile(cursor.getString(1));
                if (file != null && revision(file).equals(request.revision)) return new Resolved(file, item(cursor, file));
            }
        }
        throw new LibraryException("This item was removed or changed on Glass. Refresh the gallery.");
    }

    private static File indexedMediaFile(String path) throws IOException {
        if (path == null) return null;
        File root = Environment.getExternalStorageDirectory().getCanonicalFile();
        File file = new File(path).getCanonicalFile();
        return file.isFile() && file.getPath().startsWith(root.getPath() + File.separator) ? file : null;
    }

    private static MediaLibraryItem item(Cursor cursor, File file) {
        MediaLibraryItem item = new MediaLibraryItem();
        item.id = String.valueOf(cursor.getLong(0));
        item.name = file.getName();
        item.kind = cursor.getInt(3) == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO ? "Video" : "Photo";
        item.mimeType = cursor.getString(2);
        if (item.mimeType == null) item.mimeType = "Video".equals(item.kind) ? "video/mp4" : "image/jpeg";
        item.size = file.length();
        item.modifiedTimeMs = file.lastModified();
        item.revision = revision(file);
        return item;
    }

    private static String revision(File file) { return file.lastModified() + ":" + file.length(); }

    private static long numericId(String text) throws IOException {
        try {
            long id = Long.parseLong(text);
            if (id > 0) return id;
        } catch (NumberFormatException ignored) { }
        throw new LibraryException("Invalid media identifier.");
    }

    private static final class Resolved {
        final File file;
        final MediaLibraryItem item;
        Resolved(File file, MediaLibraryItem item) { this.file = file; this.item = item; }
    }

    private static final class LibraryException extends IOException {
        LibraryException(String message) { super(message); }
    }
}
