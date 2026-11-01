package com.damn.anotherglass.glass.host.bluetooth;

import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.SystemClock;

import com.damn.anotherglass.shared.rpc.IRPCClient;
import com.damn.anotherglass.shared.rpc.JsonFrames;
import com.damn.anotherglass.shared.rpc.PingAPI;
import com.damn.anotherglass.shared.rpc.RPCHandler;
import com.damn.anotherglass.shared.rpc.RPCMessage;
import com.damn.anotherglass.shared.rpc.RPCMessageListener;

import java.io.ByteArrayOutputStream;
import java.util.ArrayDeque;
import java.util.Arrays;
import java.util.UUID;

/** API 19 GATT central. The iPhone is a background-capable BLE peripheral. */
public final class BluetoothLEClient implements IRPCClient {
    private static final UUID SERVICE = UUID.fromString("05f2934c-1e81-4554-bb08-44aa761afbfc");
    private static final UUID RX = UUID.fromString("b4e1cb2c-f87d-49bb-a02a-a5eb6b0af001");
    private static final UUID TX = UUID.fromString("b4e1cb2c-f87d-49bb-a02a-a5eb6b0af002");
    private static final UUID CCC = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");
    private static final int MAX_BYTES = 64 * 1024;
    private static final int PACKET_BYTES = 20; // API 19 uses the default 23-byte ATT MTU.

    private HandlerThread thread;
    private Handler worker;
    private Context context;
    private RPCHandler listener;
    private BluetoothAdapter adapter;
    private BluetoothGatt gatt;
    private BluetoothGattCharacteristic receiveCharacteristic;
    private final ArrayDeque<byte[]> outgoing = new ArrayDeque<>();
    private final ByteArrayOutputStream incoming = new ByteArrayOutputStream();
    private byte[] current;
    private int offset;
    private int queuedBytes;
    private int writeLength;
    private boolean ready;
    private boolean scanning;
    private volatile boolean active;
    private long lastReceived;
    private long lastSent;
    private int reconnectDelay = 2000;

    @Override public void start(Context context, RPCMessageListener callback) {
        if (active) return;
        this.context = context.getApplicationContext();
        listener = new RPCHandler(callback);
        BluetoothManager manager = (BluetoothManager) context.getSystemService(Context.BLUETOOTH_SERVICE);
        adapter = manager != null ? manager.getAdapter() : null;
        if (adapter == null || !context.getPackageManager().hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
            listener.onConnectionLost("Bluetooth LE is not supported by this Glass firmware.");
            listener.onShutdown();
            return;
        }
        active = true;
        thread = new HandlerThread("AnotherGlass-BLE");
        thread.start();
        worker = new Handler(thread.getLooper());
        worker.post(this::scan);
    }

    @Override public void send(RPCMessage message) {
        Handler handler = worker;
        if (active && handler != null) handler.post(() -> enqueue(message));
    }

    @Override public void stop() {
        active = false;
        Handler handler = worker;
        if (handler != null) handler.post(() -> {
            handler.removeCallbacksAndMessages(null);
            clearConnection();
            thread.quitSafely();
        });
    }

    private final BluetoothAdapter.LeScanCallback scanCallback = (device, rssi, bytes) -> {
        Handler handler = worker;
        if (active && handler != null) handler.post(() -> connect(device));
    };

    private void scan() {
        if (!active) return;
        listener.onWaiting();
        if (!adapter.isEnabled()) {
            worker.postDelayed(this::scan, 5000);
            return;
        }
        scanning = adapter.startLeScan(new UUID[]{SERVICE}, scanCallback);
        worker.postDelayed(scanTimeout, 15000);
    }

    private final Runnable scanTimeout = () -> {
        if (!active || gatt != null) return;
        stopScan();
        worker.postDelayed(this::scan, reconnectDelay);
        reconnectDelay = Math.min(30000, reconnectDelay * 2);
    };

    private void stopScan() {
        worker.removeCallbacks(scanTimeout);
        if (scanning) { adapter.stopLeScan(scanCallback); scanning = false; }
    }

    private void connect(BluetoothDevice device) {
        if (!active || gatt != null || !scanning) return;
        stopScan();
        // The API 18 overload is required by the original Explorer firmware.
        gatt = device.connectGatt(context, false, callbacks);
        if (gatt == null) { retry("Could not connect to the iPhone."); return; }
        worker.postDelayed(connectTimeout, 20000);
    }

    private final Runnable connectTimeout = () -> {
        if (active && !ready) retry("Bluetooth setup timed out. Keep the iPhone app open while connecting.");
    };

    private final BluetoothGattCallback callbacks = new BluetoothGattCallback() {
        @Override public void onConnectionStateChange(BluetoothGatt source, int status, int state) {
            dispatch(() -> {
                if (source != gatt) return;
                if (status != BluetoothGatt.GATT_SUCCESS || state == BluetoothProfile.STATE_DISCONNECTED) {
                    retry("Bluetooth connection lost.");
                } else if (state == BluetoothProfile.STATE_CONNECTED && !source.discoverServices()) {
                    retry("Could not discover the iPhone companion service.");
                }
            });
        }

        @Override public void onServicesDiscovered(BluetoothGatt source, int status) {
            dispatch(() -> {
                if (source != gatt) return;
                BluetoothGattService service = source.getService(SERVICE);
                receiveCharacteristic = service != null ? service.getCharacteristic(RX) : null;
                BluetoothGattCharacteristic transmit = service != null ? service.getCharacteristic(TX) : null;
                BluetoothGattDescriptor descriptor = transmit != null ? transmit.getDescriptor(CCC) : null;
                if (status != BluetoothGatt.GATT_SUCCESS || receiveCharacteristic == null || descriptor == null
                        || !source.setCharacteristicNotification(transmit, true)) {
                    retry("The iPhone Bluetooth service is unavailable. Restart the companion."); return;
                }
                descriptor.setValue(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE);
                if (!source.writeDescriptor(descriptor)) retry("Could not subscribe to the iPhone.");
            });
        }

        @Override public void onDescriptorWrite(BluetoothGatt source, BluetoothGattDescriptor descriptor, int status) {
            dispatch(() -> {
                if (source != gatt || !CCC.equals(descriptor.getUuid())) return;
                if (status != BluetoothGatt.GATT_SUCCESS) { retry("Bluetooth subscription failed."); return; }
                worker.removeCallbacks(connectTimeout);
                ready = true;
                reconnectDelay = 2000;
                lastReceived = lastSent = SystemClock.elapsedRealtime();
                listener.onConnectionStarted("iPhone · Bluetooth LE");
                worker.post(heartbeat);
                pumpWrites();
            });
        }

        @Override public void onCharacteristicChanged(BluetoothGatt source, BluetoothGattCharacteristic characteristic) {
            byte[] value = characteristic.getValue();
            byte[] bytes = value != null ? value.clone() : new byte[0];
            dispatch(() -> { if (source == gatt) receive(bytes); });
        }

        @Override public void onCharacteristicWrite(BluetoothGatt source, BluetoothGattCharacteristic characteristic, int status) {
            dispatch(() -> {
                if (source != gatt) return;
                if (status != BluetoothGatt.GATT_SUCCESS) { retry("The iPhone ended the Bluetooth session."); return; }
                offset += writeLength;
                writeLength = 0;
                lastSent = SystemClock.elapsedRealtime();
                if (current != null && offset == current.length) {
                    queuedBytes -= current.length;
                    current = null;
                    offset = 0;
                }
                pumpWrites();
            });
        }
    };

    private void dispatch(Runnable block) {
        Handler handler = worker;
        if (active && handler != null) handler.post(() -> { if (active) block.run(); });
    }

    private void receive(byte[] bytes) {
        lastReceived = SystemClock.elapsedRealtime();
        try {
            for (byte value : bytes) {
                if (value == '\n') {
                    if (incoming.size() == 0) continue;
                    RPCMessage message = JsonFrames.decode(incoming.toByteArray());
                    incoming.reset();
                    if (message == null || message.service == null) { retry("The iPhone disconnected."); return; }
                    if (PingAPI.ID.equals(message.service)) enqueue(new RPCMessage(PingAPI.PONG_ID, null));
                    else if (!PingAPI.PONG_ID.equals(message.service)) listener.onDataReceived(message);
                } else {
                    if (incoming.size() >= MAX_BYTES) throw new IllegalArgumentException();
                    incoming.write(value);
                }
            }
        } catch (Exception e) { retry("Invalid Bluetooth message. Update both companion apps."); }
    }

    private void enqueue(RPCMessage message) {
        if (!active || !ready) return;
        try {
            byte[] bytes = JsonFrames.encode(message);
            if (bytes.length > MAX_BYTES || queuedBytes + bytes.length > MAX_BYTES) {
                retry("Bluetooth send queue exceeded its limit."); return;
            }
            outgoing.add(bytes);
            queuedBytes += bytes.length;
            pumpWrites();
        } catch (Exception e) { retry("Could not encode a Bluetooth message."); }
    }

    private void pumpWrites() {
        if (!active || !ready || gatt == null || writeLength != 0) return;
        if (current == null) { current = outgoing.poll(); offset = 0; }
        if (current == null) return;
        writeLength = Math.min(PACKET_BYTES, current.length - offset);
        receiveCharacteristic.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT);
        receiveCharacteristic.setValue(Arrays.copyOfRange(current, offset, offset + writeLength));
        if (!gatt.writeCharacteristic(receiveCharacteristic)) retry("Could not write to the iPhone.");
    }

    private final Runnable heartbeat = new Runnable() {
        @Override public void run() {
            if (!active || !ready) return;
            long now = SystemClock.elapsedRealtime();
            if (now - lastReceived > 45000) { retry("The iPhone stopped responding over Bluetooth."); return; }
            if (now - lastSent >= 5000) enqueue(new RPCMessage(PingAPI.ID, null));
            worker.postDelayed(this, 5000);
        }
    };

    private void retry(String error) {
        if (!active) return;
        boolean wasReady = ready;
        clearConnection();
        if (wasReady) listener.onConnectionLost(error);
        listener.onWaiting();
        worker.postDelayed(this::scan, reconnectDelay);
        reconnectDelay = Math.min(30000, reconnectDelay * 2);
    }

    private void clearConnection() {
        worker.removeCallbacks(connectTimeout);
        worker.removeCallbacks(heartbeat);
        stopScan();
        ready = false;
        BluetoothGatt previous = gatt;
        gatt = null;
        if (previous != null) { previous.disconnect(); previous.close(); }
        receiveCharacteristic = null;
        outgoing.clear();
        current = null;
        offset = queuedBytes = writeLength = 0;
        incoming.reset();
    }
}
