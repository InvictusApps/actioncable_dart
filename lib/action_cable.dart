import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/io.dart';

import 'channel_id.dart';

typedef _OnConnectedFunction = void Function();
typedef _OnConnectionLostFunction = void Function();
typedef _OnCannotConnectFunction = void Function();
typedef _OnChannelSubscribedFunction = void Function();
typedef _OnChannelDisconnectedFunction = void Function();
typedef _OnChannelMessageFunction = void Function(Map message);

class ActionCable {
  DateTime? _lastPing;
  late Timer _timer;
  late IOWebSocketChannel _socketChannel;
  late StreamSubscription _listener;
  late Duration pingInterval;
  _OnConnectedFunction? onConnected;
  _OnCannotConnectFunction? onCannotConnect;
  _OnConnectionLostFunction? onConnectionLost;
  Map<String, _OnChannelSubscribedFunction?> _onChannelSubscribedCallbacks = {};
  Map<String, _OnChannelDisconnectedFunction?> _onChannelDisconnectedCallbacks =
      {};
  Map<String, _OnChannelMessageFunction?> _onChannelMessageCallbacks = {};

  ActionCable.Connect(
    String url, {
    Map<String, String> headers: const {},
    this.onConnected,
    this.onConnectionLost,
    this.onCannotConnect,
    this.pingInterval = const Duration(seconds: 3),
  }) {
    // rails gets a ping every 3 seconds
    _socketChannel = IOWebSocketChannel.connect(url,
        headers: headers, pingInterval: pingInterval);
    _listener = _socketChannel.stream.listen(_onData, onError: (_) {
      this.disconnect(); // close a socket and the timer
      if (this.onCannotConnect != null) this.onCannotConnect!();
    });
    _timer = Timer.periodic(pingInterval, healthCheck);
  }

  void disconnect() {
    _timer.cancel();
    _socketChannel.sink.close();
    _listener.cancel();
  }

  // check if there is no ping for pingInterval and signal a [onConnectionLost] if
  // there is no ping for more than 2 pingIntervals
  void healthCheck(_) {
    if (_lastPing == null) {
      return;
    }
    if (DateTime.now().difference(_lastPing!) > pingInterval * 2) {
      this.disconnect();
      if (this.onConnectionLost != null) this.onConnectionLost!();
    }
  }

  // channelName being 'Chat' will be considered as 'ChatChannel',
  // 'Chat', { id: 1 } => { channel: 'ChatChannel', id: 1 }
  void subscribe(String channelName,
      {Map? channelParams,
      _OnChannelSubscribedFunction? onSubscribed,
      _OnChannelDisconnectedFunction? onDisconnected,
      _OnChannelMessageFunction? onMessage}) {
    final channelId = encodeChannelId(channelName, channelParams);

    _onChannelSubscribedCallbacks[channelId] = onSubscribed;
    _onChannelDisconnectedCallbacks[channelId] = onDisconnected;
    _onChannelMessageCallbacks[channelId] = onMessage;

    _send({'identifier': channelId, 'command': 'subscribe'});
  }

  void unsubscribe(String channelName, {Map? channelParams}) {
    final channelId = encodeChannelId(channelName, channelParams);

    _onChannelSubscribedCallbacks[channelId] = null;
    _onChannelDisconnectedCallbacks[channelId] = null;
    _onChannelMessageCallbacks[channelId] = null;

    _socketChannel.sink
        .add(jsonEncode({'identifier': channelId, 'command': 'unsubscribe'}));
  }

  void performAction(String channelName,
      {String? action, Map? channelParams, Map? actionParams}) {
    final channelId = encodeChannelId(channelName, channelParams);

    actionParams ??= {};
    actionParams['action'] = action;

    _send({
      'identifier': channelId,
      'command': 'message',
      'data': jsonEncode(actionParams)
    });
  }

  void _onData(dynamic payload) {
    payload = jsonDecode(payload);

    if (payload['type'] != null) {
      _handleProtocolMessage(payload);
    } else {
      _handleDataMessage(payload);
    }
  }

  void _handleProtocolMessage(Map payload) {
    try {
      switch (payload['type']) {
        case 'ping':
          // rails sends epoch as seconds not miliseconds
          _lastPing =
              DateTime.fromMillisecondsSinceEpoch(payload['message'] * 1000);
          break;
        case 'welcome':
          if (onConnected != null) {
            onConnected!();
          }
          break;
        case 'disconnect':
          final channelId = parseChannelId(payload['identifier']);
          final onDisconnected = _onChannelDisconnectedCallbacks[channelId];
          if (onDisconnected != null) {
            onDisconnected();
          }
          break;
        case 'confirm_subscription':
          final channelId = parseChannelId(payload['identifier']);
          final onSubscribed = _onChannelSubscribedCallbacks[channelId];
          if (onSubscribed != null) {
            onSubscribed();
          }
          break;
        case 'reject_subscription':
          // throw 'Unimplemented';
          break;
        default:
          throw 'InvalidMessage';
      }
    } catch (e) {
      print("[ACTION_CABLE] ERROR handling protocol message");
    }
  }

  void _handleDataMessage(Map payload) {
    final channelId = parseChannelId(payload['identifier']);
    final onMessage = _onChannelMessageCallbacks[channelId];
    if (onMessage != null) {
      onMessage(payload['message']);
    }
  }

  void _send(Map payload) {
    _socketChannel.sink.add(jsonEncode(payload));
  }
}
