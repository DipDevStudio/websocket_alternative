import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

abstract class WebSocketAlternative {
  static Future<WebSocketAlternative> connect(
    Uri uri, {
    Iterable<String>? protocols,
    Map<String, dynamic>? headers,
    Duration timeout = const Duration(seconds: 4),
  }) =>
      _WebSocketAlternativeImpl.connect(uri);

  void add(Uint8List data);
  StreamSubscription<dynamic> listen(void Function(dynamic event)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError});
}

class _WebSocketAlternativeImpl implements WebSocketAlternative {
  final Uri uri;
  final Iterable<String>? protocols;
  final Map<String, dynamic>? headers;

  WebSocket? _webSocket;
  Socket? _socket;

  static Future<WebSocketAlternative> connect(
    Uri uri, {
    Iterable<String>? protocols,
    Map<String, dynamic>? headers,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    uri = Uri(
        scheme: uri.isScheme('wss') ? 'https' : 'http',
        userInfo: uri.userInfo,
        host: uri.host,
        port: uri.port,
        path: uri.path,
        query: uri.query,
        fragment: uri.fragment);

    print('Connecting to $uri');
    return Socket.connect(uri.host, uri.port, timeout: timeout).then(
      (socket) {
        final instance = _WebSocketAlternativeImpl(
          uri: uri,
          headers: headers,
          protocols: protocols,
        );

        return instance._upgradeSocket(socket).then((_) => instance);
      },
    );
  }

  _WebSocketAlternativeImpl({required this.uri, this.protocols, this.headers});

  @override
  void add(Uint8List data) {
    print('Data send:\n$data');
    try {
      //_socket!.write(data);
      _webSocket!.add(data);
    } catch (e) {
      print(e);
    }
  }

  @override
  StreamSubscription<dynamic> listen(void Function(dynamic event)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    return _webSocket!.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  Future<void> _upgradeSocket(Socket socket) {
    final comleter = Completer<void>();

    final stream = _DetachedIncoming(socket.listen((event) {
      final responce = String.fromCharCodes(event);
      print('Data recive:\n$responce');
      if (responce.contains('HTTP/1.1 101 Switching Protocols')) {
        comleter.complete();
      }
    }), null);

    final send = _generateHTTPSwitchRequest(
            uri: uri, headers: headers, protocols: protocols)
        .join('\r\n');
    print('Data send:\n$send');
    socket.write(send);

    return comleter.future.then((_) {
      _socket = socket;
      final s = _DetachedSocket(socket, stream);
      _webSocket = WebSocket.fromUpgradedSocket(s, serverSide: false);
    });
  }

  List<String> _generateHTTPSwitchRequest({
    required Uri uri,
    Iterable<String>? protocols,
    Map<String, dynamic>? headers,
  }) {
    Random random = Random();
    // Generate 16 random bytes.
    Uint8List nonceData = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      nonceData[i] = random.nextInt(256);
    }

    String nonce = base64Encode(nonceData);
    final requestHeaders = <String, String>{};

    if (uri.userInfo.isNotEmpty) {
      // If the URL contains user information use that for basic
      // authorization.
      String auth = base64Encode(utf8.encode(uri.userInfo));
      requestHeaders[HttpHeaders.authorizationHeader] = 'Basic $auth';
    }
    if (headers != null) {
      headers.forEach((field, value) {
        requestHeaders[field] = value;
      });
    }
    // Setup the initial handshake.
    requestHeaders['Host'] = uri.host;
    requestHeaders[HttpHeaders.connectionHeader] = 'Upgrade';
    requestHeaders[HttpHeaders.upgradeHeader] = 'websocket';
    requestHeaders['Sec-WebSocket-Key'] = nonce;
    requestHeaders['Cache-Control'] = 'no-cache';
    requestHeaders['Sec-WebSocket-Version'] = '13';

    if (protocols != null) {
      requestHeaders['Sec-WebSocket-Protocol'] = protocols.toList().join(', ');
    }

    return List<String>.from([
      'GET /${uri.path} HTTP/1.1',
      ...requestHeaders.entries.map((e) => '${e.key}: ${e.value}').toList(),
      ''
    ]);
  }
}

class _DetachedIncoming extends Stream<Uint8List> {
  final StreamSubscription<Uint8List>? subscription;
  final Uint8List? bufferedData;

  _DetachedIncoming(this.subscription, this.bufferedData);

  @override
  StreamSubscription<Uint8List> listen(void Function(Uint8List event)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    var subscription = this.subscription;
    if (subscription != null) {
      subscription
        ..onData(onData)
        ..onError(onError)
        ..onDone(onDone);
      if (bufferedData == null) {
        return subscription..resume();
      }
      return _DetachedStreamSubscription(subscription, bufferedData, onData)
        ..resume();
    } else {
      return Stream<Uint8List>.fromIterable([bufferedData!]).listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
    }
  }
}

class _DetachedStreamSubscription implements StreamSubscription<Uint8List> {
  final StreamSubscription<Uint8List> _subscription;
  Uint8List? _injectData;
  void Function(Uint8List data)? _userOnData;
  bool _isCanceled = false;
  bool _scheduled = false;
  int _pauseCount = 1;

  _DetachedStreamSubscription(
      this._subscription, this._injectData, this._userOnData);

  @override
  bool get isPaused => _subscription.isPaused;

  @override
  Future<T> asFuture<T>([T? futureValue]) =>
      _subscription.asFuture<T>(futureValue as T);

  @override
  Future cancel() {
    _isCanceled = true;
    _injectData = null;
    return _subscription.cancel();
  }

  @override
  void onData(void Function(Uint8List data)? handleData) {
    _userOnData = handleData;
    _subscription.onData(handleData);
  }

  @override
  void onDone(void Function()? handleDone) {
    _subscription.onDone(handleDone);
  }

  @override
  void onError(Function? handleError) {
    _subscription.onError(handleError);
  }

  @override
  void pause([Future? resumeSignal]) {
    if (_injectData == null) {
      _subscription.pause(resumeSignal);
    } else {
      _pauseCount++;
      if (resumeSignal != null) {
        resumeSignal.whenComplete(resume);
      }
    }
  }

  @override
  void resume() {
    if (_injectData == null) {
      _subscription.resume();
    } else {
      _pauseCount--;
      _maybeScheduleData();
    }
  }

  void _maybeScheduleData() {
    if (_scheduled) return;
    if (_pauseCount != 0) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      if (_pauseCount > 0 || _isCanceled) return;
      var data = _injectData!;
      _injectData = null;
      _subscription.resume();
      _userOnData?.call(data);
    });
  }
}

class _DetachedSocket extends Stream<Uint8List> implements Socket {
  final Stream<Uint8List> _incoming;
  final Socket _socket;

  _DetachedSocket(this._socket, this._incoming);

  @override
  StreamSubscription<Uint8List> listen(void Function(Uint8List event)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    return _incoming.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  Encoding get encoding => _socket.encoding;

  @override
  set encoding(Encoding value) {
    _socket.encoding = value;
  }

  @override
  void write(Object? obj) {
    _socket.write(obj);
  }

  @override
  void writeln([Object? obj = ""]) {
    _socket.writeln(obj);
  }

  @override
  void writeCharCode(int charCode) {
    _socket.writeCharCode(charCode);
  }

  @override
  void writeAll(Iterable objects, [String separator = ""]) {
    _socket.writeAll(objects, separator);
  }

  @override
  void add(List<int> bytes) {
    _socket.add(bytes);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    return _socket.addError(error, stackTrace);
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    return _socket.addStream(stream);
  }

  @override
  void destroy() => _socket.destroy();

  @override
  Future<void> flush() => _socket.flush();

  @override
  Future<void> close() => _socket.close();

  @override
  Future get done => _socket.done;

  @override
  int get port => _socket.port;

  @override
  InternetAddress get address => _socket.address;

  @override
  InternetAddress get remoteAddress => _socket.remoteAddress;

  @override
  int get remotePort => _socket.remotePort;

  @override
  bool setOption(SocketOption option, bool enabled) {
    return _socket.setOption(option, enabled);
  }

  @override
  Uint8List getRawOption(RawSocketOption option) {
    return _socket.getRawOption(option);
  }

  @override
  void setRawOption(RawSocketOption option) {
    _socket.setRawOption(option);
  }
}
