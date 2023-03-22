import 'dart:typed_data';

import 'package:socket/web_socket_alternative.dart';

void main(List<String> arguments) async {
  final uri = Uri.parse('ws://192.168.30.44:6432');

  final socket = await WebSocketAlternative.connect(uri);

  socket.listen((event) {
    if (event is List<int>) {
      print(
          'Data received:\n${event.map((e) => e.toRadixString(16)).toList()}');
      print('Data received:\n${String.fromCharCodes(event)}');
    } else {
      print('Data received:\n${event.toString()}');
    }
  });

  for (var i = 0; i < 10; i++) {
    await Future.delayed(
      Duration(seconds: 1),
      () => socket.add(Uint8List.fromList(
          [0x7B, 0x7B, 0x95, 0x03, 0x00, 0x00, 0x00, 0x88, 0x7D, 0x7D])),
    );
  }
}
