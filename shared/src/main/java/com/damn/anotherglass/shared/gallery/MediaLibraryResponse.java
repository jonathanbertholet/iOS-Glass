package com.damn.anotherglass.shared.gallery;

import java.io.Serializable;
import java.util.List;

public class MediaLibraryResponse implements Serializable {
    public String requestId;
    public String operation;
    public String mediaId;
    public String error;
    public List<MediaLibraryItem> items;
    public boolean hasMore;
    public String nextBeforeId;
    public byte[] data; // Existing JSON serializer encodes this as Base64.
    public long offset;
    public long totalBytes;
}
