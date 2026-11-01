package com.damn.anotherglass.shared.gallery;

import java.io.Serializable;

public class MediaLibraryItem implements Serializable {
    public String id;
    public String name;
    public String kind; // Photo or Video
    public String mimeType;
    public long size;
    public long modifiedTimeMs;
    public String revision;
}
