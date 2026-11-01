package com.damn.anotherglass.shared.rpc;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;

/** The same JSON Lines format over a packet-based transport. */
public final class JsonFrames {
    private JsonFrames() { }

    public static byte[] encode(RPCMessage message) throws Exception {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        new JsonMessageSerializer(new ByteArrayInputStream(new byte[0]), output).writeMessage(message);
        return output.toByteArray();
    }

    public static RPCMessage decode(byte[] line) throws Exception {
        return new JsonMessageSerializer(new ByteArrayInputStream(line), new ByteArrayOutputStream()).readMessage();
    }
}
