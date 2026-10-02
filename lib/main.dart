import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MailRTC',
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

/// SDPを gzip + base64 で短縮したコードにする
class SdpCodec {
  static String encode(RTCSessionDescription desc) {
    final json = jsonEncode({'t': desc.type, 's': desc.sdp});
    final bytes = gzip.encode(utf8.encode(json));
    return base64Url.encode(bytes);
  }

  static RTCSessionDescription decode(String code) {
    final cleaned = code.replaceAll(RegExp(r'\s'), '');
    final bytes = gzip.decode(base64Url.decode(cleaned));
    final map = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    return RTCSessionDescription(map['s'] as String, map['t'] as String);
  }
}

enum Role { none, host, guest }

class ChatMessage {
  final String text;
  final bool mine;
  final DateTime time;

  ChatMessage(this.text, this.mine) : time = DateTime.now();
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const Map<String, dynamic> _config = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  RTCPeerConnection? _pc;
  RTCDataChannel? _channel;

  Role _role = Role.none;
  bool _busy = false;
  bool _connected = false;
  String _status = '未接続';

  String _localCode = '';

  final _toController = TextEditingController();
  final _remoteController = TextEditingController();
  final _msgController = TextEditingController();
  final _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];

  @override
  void dispose() {
    _channel?.close();
    _pc?.close();
    _toController.dispose();
    _remoteController.dispose();
    _msgController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _resetConnection() async {
    await _channel?.close();
    await _pc?.close();
    _channel = null;
    _pc = null;
    setState(() {
      _role = Role.none;
      _busy = false;
      _connected = false;
      _status = '未接続';
      _localCode = '';
      _remoteController.clear();
      _messages.clear();
    });
  }

  Future<RTCPeerConnection> _createPeer() async {
    final pc = await createPeerConnection(_config);
    pc.onConnectionState = (state) {
      if (!mounted) return;
      setState(() {
        switch (state) {
          case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
            _status = '接続済み';
            break;
          case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
            _status = '接続中...';
            break;
          case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
            _status = '接続に失敗しました';
            _connected = false;
            break;
          case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
            _status = '切断されました';
            _connected = false;
            break;
          case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
            _status = '終了';
            _connected = false;
            break;
          default:
            break;
        }
      });
    };
    return pc;
  }

  void _setupChannel(RTCDataChannel ch) {
    _channel = ch;
    ch.onDataChannelState = (state) {
      if (!mounted) return;
      setState(() {
        _connected = state == RTCDataChannelState.RTCDataChannelOpen;
        if (_connected) _status = '接続済み';
      });
    };
    ch.onMessage = (data) {
      if (data.isBinary) return;
      if (!mounted) return;
      setState(() => _messages.add(ChatMessage(data.text, false)));
      _scrollToBottom();
    };
  }

  /// ICE候補の収集完了を待つ(Non-trickle方式)
  Future<void> _waitIceComplete(RTCPeerConnection pc) async {
    if (pc.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      return;
    }
    final completer = Completer<void>();
    pc.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !completer.isCompleted) {
        completer.complete();
      }
    };
    await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {},
    );
  }

  // ---------- ホスト側: オファー作成 ----------
  Future<void> _createOffer() async {
    setState(() {
      _busy = true;
      _role = Role.host;
      _status = '接続コード作成中...';
    });
    try {
      final pc = await _createPeer();
      _pc = pc;
      final ch = await pc.createDataChannel(
        'chat',
        RTCDataChannelInit()..ordered = true,
      );
      _setupChannel(ch);
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await _waitIceComplete(pc);
      final local = await pc.getLocalDescription();
      setState(() {
        _localCode = SdpCodec.encode(local!);
        _status = 'オファー作成完了。メールで相手に送ってください';
      });
    } catch (e) {
      _toast('オファー作成に失敗しました: $e');
      await _resetConnection();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- ゲスト側: オファー受信 → アンサー作成 ----------
  Future<void> _createAnswer() async {
    final code = _remoteController.text.trim();
    if (code.isEmpty) {
      _toast('相手から届いたコードを貼り付けてください');
      return;
    }
    setState(() {
      _busy = true;
      _role = Role.guest;
      _status = 'アンサー作成中...';
    });
    try {
      final offer = SdpCodec.decode(code);
      final pc = await _createPeer();
      _pc = pc;
      pc.onDataChannel = (ch) => _setupChannel(ch);
      await pc.setRemoteDescription(offer);
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      await _waitIceComplete(pc);
      final local = await pc.getLocalDescription();
      setState(() {
        _localCode = SdpCodec.encode(local!);
        _status = 'アンサー作成完了。メールで相手に返信してください';
      });
    } catch (e) {
      _toast('アンサー作成に失敗しました。コードを確認してください: $e');
      await _resetConnection();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- ホスト側: アンサー受信 → 接続 ----------
  Future<void> _applyAnswer() async {
    final code = _remoteController.text.trim();
    if (code.isEmpty) {
      _toast('相手から届いたアンサーを貼り付けてください');
      return;
    }
    setState(() {
      _busy = true;
      _status = '接続中...';
    });
    try {
      final answer = SdpCodec.decode(code);
      await _pc!.setRemoteDescription(answer);
    } catch (e) {
      _toast('アンサーの適用に失敗しました: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- メール ----------
  Future<void> _sendMail() async {
    if (_localCode.isEmpty) return;
    final isOffer = _role == Role.host;
    final subject = isOffer ? 'MailRTC 接続オファー' : 'MailRTC 接続アンサー';
    final body = '${isOffer ? "以下のコードをアプリに貼り付けてください(オファー)" : "以下のコードをアプリに貼り付けてください(アンサー)"}\n\n$_localCode';
    final to = _toController.text.trim();
    final uri = Uri.parse(
      'mailto:${Uri.encodeComponent(to)}'
      '?subject=${Uri.encodeComponent(subject)}'
      '&body=${Uri.encodeComponent(body)}',
    );
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) _toast('メールアプリを起動できませんでした。コードをコピーして送信してください');
    } catch (_) {
      _toast('メールアプリを起動できませんでした。コードをコピーして送信してください');
    }
  }

  Future<void> _copyLocal() async {
    await Clipboard.setData(ClipboardData(text: _localCode));
    _toast('コードをコピーしました');
  }

  Future<void> _pasteRemote() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isEmpty) {
      _toast('クリップボードが空です');
      return;
    }
    // メール本文全体を貼られても、コード部分(最長の連続英数字列)を抽出する
    final matches = RegExp(r'[A-Za-z0-9_\-=]{50,}').allMatches(text);
    String code = text.trim();
    if (matches.isNotEmpty) {
      code = matches
          .map((m) => m.group(0)!)
          .reduce((a, b) => a.length >= b.length ? a : b);
    }
    setState(() => _remoteController.text = code);
  }

  // ---------- チャット ----------
  void _sendMessage() {
    final text = _msgController.text.trim();
    if (text.isEmpty || !_connected) return;
    _channel?.send(RTCDataChannelMessage(text));
    setState(() {
      _messages.add(ChatMessage(text, true));
      _msgController.clear();
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MailRTC'),
        actions: [
          if (_role != Role.none)
            IconButton(
              tooltip: 'リセット',
              icon: const Icon(Icons.refresh),
              onPressed: _resetConnection,
            ),
        ],
      ),
      body: SafeArea(
        child: _connected ? _buildChat() : _buildSetup(),
      ),
    );
  }

  Widget _buildSetup() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _statusCard(),
        const SizedBox(height: 12),
        if (_role == Role.none) ..._buildStart(),
        if (_role == Role.host) ..._buildHost(),
        if (_role == Role.guest) ..._buildGuest(),
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }

  Widget _statusCard() {
    return Card(
      child: ListTile(
        leading: Icon(
          _connected ? Icons.link : Icons.link_off,
          color: _connected ? Colors.green : Colors.grey,
        ),
        title: Text(_status),
      ),
    );
  }

  List<Widget> _buildStart() {
    return [
      const Text(
        'シグナリングサーバーを使わず、メールでコードを交換して直接接続します。'
        'どちらか一方が「接続を開始」、もう一方が「接続を受ける」を選んでください。',
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: _busy ? null : _createOffer,
        icon: const Icon(Icons.call_made),
        label: const Text('接続を開始する(オファー作成)'),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: _busy
            ? null
            : () => setState(() {
                  _role = Role.guest;
                  _status = '相手のオファーを貼り付けてください';
                }),
        icon: const Icon(Icons.call_received),
        label: const Text('接続を受ける(オファー受信)'),
      ),
    ];
  }

  List<Widget> _buildHost() {
    return [
      ..._localCodeSection('① このオファーをメールで相手に送る'),
      const Divider(height: 32),
      const Text('② 相手から返信されたアンサーを貼り付ける',
          style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      _remoteField('アンサーコード'),
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed: (_busy || _localCode.isEmpty) ? null : _applyAnswer,
        icon: const Icon(Icons.check),
        label: const Text('接続する'),
      ),
    ];
  }

  List<Widget> _buildGuest() {
    final answered = _localCode.isNotEmpty;
    return [
      const Text('① 相手から届いたオファーを貼り付ける',
          style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      _remoteField('オファーコード'),
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed: (_busy || answered) ? null : _createAnswer,
        icon: const Icon(Icons.reply),
        label: const Text('アンサーを作成'),
      ),
      if (answered) ...[
        const Divider(height: 32),
        ..._localCodeSection('② このアンサーをメールで相手に返信する'),
        const SizedBox(height: 8),
        const Text('相手が接続操作を行うと、自動的にチャット画面へ切り替わります。'),
      ],
    ];
  }

  Widget _remoteField(String label) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            controller: _remoteController,
            maxLines: 4,
            minLines: 2,
            style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            decoration: InputDecoration(
              labelText: label,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          tooltip: 'クリップボードから貼り付け',
          onPressed: _pasteRemote,
          icon: const Icon(Icons.paste),
        ),
      ],
    );
  }

  List<Widget> _localCodeSection(String title) {
    if (_localCode.isEmpty) return [];
    return [
      Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      TextField(
        controller: _toController,
        keyboardType: TextInputType.emailAddress,
        decoration: const InputDecoration(
          labelText: '送信先メールアドレス',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(8),
        constraints: const BoxConstraints(maxHeight: 120),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey),
          borderRadius: BorderRadius.circular(4),
        ),
        child: SingleChildScrollView(
          child: SelectableText(
            _localCode,
            style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text('コード長: ${_localCode.length} 文字',
          style: const TextStyle(fontSize: 12, color: Colors.grey)),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _sendMail,
              icon: const Icon(Icons.mail),
              label: const Text('メールで送信'),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: _copyLocal,
            icon: const Icon(Icons.copy),
            label: const Text('コピー'),
          ),
        ],
      ),
    ];
  }

  Widget _buildChat() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          color: Colors.green.withOpacity(0.15),
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
          child: const Text('P2P接続中', style: TextStyle(color: Colors.green)),
        ),
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(12),
            itemCount: _messages.length,
            itemBuilder: (context, i) {
              final m = _messages[i];
              final t = m.time;
              final hh = t.hour.toString().padLeft(2, '0');
              final mm = t.minute.toString().padLeft(2, '0');
              return Align(
                alignment:
                    m.mine ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.75,
                  ),
                  decoration: BoxDecoration(
                    color: m.mine
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).colorScheme.surfaceVariant,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      SelectableText(m.text),
                      Text('$hh:$mm',
                          style: const TextStyle(
                              fontSize: 10, color: Colors.grey)),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _msgController,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    hintText: 'メッセージを入力',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _sendMessage,
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
