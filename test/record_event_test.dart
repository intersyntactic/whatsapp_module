import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_docking_station_api/is_docking_station_api.dart';
import 'package:is_logbook_format/is_logbook_format.dart';
import 'package:is_whatsapp_module/is_whatsapp_module.dart';
import 'package:test/test.dart';

/// A writer that takes one request on [path], keeps it, and answers [line].
Future<(ServerSocket, Future<List<int>>)> _writer(
  String path,
  String line,
) async {
  final server = await ServerSocket.bind(
    InternetAddress(path, type: InternetAddressType.unix),
    0,
  );
  final request = server.first.then((socket) async {
    final bytes = await socket.fold<List<int>>([], (a, b) => a..addAll(b));
    socket.write(line);
    await socket.close();
    return bytes;
  });
  return (server, request);
}

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('record'));
  tearDown(() => dir.delete(recursive: true));

  test('writes an entry the docking station reads back', () async {
    final (server, request) = await _writer('${dir.path}/w.sock', 'ok ab12');
    final bytes = Uint8List.fromList(utf8.encode('{"object":"x"}'));
    final at = DateTime.utc(2026, 11, 28, 1, 2, 3);

    final answer = await recordEvent(
      '${dir.path}/w.sock',
      source: RelayedEventSource.parse('whatsapp')!,
      bytes: bytes,
      at: at,
    );
    await server.close();

    expect(answer, isA<Recorded>());
    final sent = await request;
    final firstBreak = sent.indexOf(10);
    final secondBreak = sent.indexOf(10, firstBreak + 1);
    final kind = utf8.decode(sent.sublist(0, firstBreak));
    expect(kind, 'whatsapp-event');
    expect(utf8.decode(sent.sublist(firstBreak + 1, secondBreak)), '-');

    final event = RelayedEvent.read(
      ObjectId.parse('0' * 64)!,
      Kind.parse(kind)!,
      Uint8List.fromList(sent.sublist(secondBreak + 1)),
    );
    expect(event, isNotNull);
    expect(event!.source.value, 'whatsapp');
    expect(event.at, at);
    expect(event.bytes, bytes);
  });
}
