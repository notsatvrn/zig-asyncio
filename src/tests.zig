const std = @import("std");
const folio = @import("folio");

// UDP

const UDPStream = folio.net.UDPStream;

fn udpServerTask(addr: std.net.Address, startup: *folio.ResetEvent) !void {
    var stream = try UDPStream.init(addr);
    try stream.bind(addr);
    startup.set();

    var recv_buf: [14]u8 = undefined;
    const read = try stream.recvFrom(&recv_buf);
    try std.testing.expectEqual(@as(usize, 14), read[0]);
    try std.testing.expect(std.mem.eql(u8, &recv_buf[0..].*, "Hello, Server!"));

    try stream.deinit();
}

fn udpClientTask(addr: std.net.Address, startup: *folio.ResetEvent) !void {
    try startup.wait();
    var stream = try UDPStream.init(addr);

    const written = try stream.sendTo(addr, "Hello, Server!");
    try std.testing.expectEqual(@as(usize, 14), written);

    try stream.deinit();
}

fn udpWorker() !void {
    const address = try std.net.Address.parseIp4("127.0.0.1", 1327);
    var startup = folio.ResetEvent{};

    _ = try folio.spawn(udpServerTask, .{ address, &startup });
    _ = try folio.spawn(udpClientTask, .{ address, &startup });
    try folio.run(.wait);
}

test UDPStream {
    const rt = try folio.Runtime.init(std.testing.allocator);
    defer rt.deinit();

    var worker = try rt.spawnWorker(udpWorker, .{});
    worker.join();
}

// TCP

const TCPListener = folio.net.TCPListener;
const TCPStream = folio.net.TCPStream;

fn tcpServerTask(addr: std.net.Address, startup: *folio.ResetEvent) !void {
    const listener = try TCPListener.init(addr, null);
    startup.set();

    const client = try listener.accept();

    var recv_buf: [14]u8 = undefined;
    const read = try client.recv(&recv_buf);
    try std.testing.expectEqual(@as(usize, 14), read);
    try std.testing.expect(std.mem.eql(u8, &recv_buf, "Hello, Server!"));

    try listener.deinit();
}

fn tcpClientTask(addr: std.net.Address, startup: *folio.ResetEvent) !void {
    try startup.wait();
    var stream = try TCPStream.init(addr);

    const written = try stream.send("Hello, Server!");
    try std.testing.expectEqual(@as(usize, 14), written);

    try stream.deinit();
}

fn tcpWorker() !void {
    const address = try std.net.Address.parseIp4("127.0.0.1", 1327);
    var startup = folio.ResetEvent{};

    _ = try folio.spawn(tcpServerTask, .{ address, &startup });
    _ = try folio.spawn(tcpClientTask, .{ address, &startup });
    try folio.run(.wait);
}

test "TCP" {
    const rt = try folio.Runtime.init(std.testing.allocator);
    defer rt.deinit();

    var worker = try rt.spawnWorker(tcpWorker, .{});
    worker.join();
}
