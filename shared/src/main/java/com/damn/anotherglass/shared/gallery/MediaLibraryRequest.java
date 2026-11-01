package com.damn.anotherglass.shared.gallery;

import java.io.Serializable;

public class MediaLibraryRequest implements Serializable {
    public String requestId;
    public String operation; // List, Thumbnail, Read
    public String mediaId;
    public String revision;
    public String beforeId;
    public int pageSize;
    public long offset;
    public int length;
}
