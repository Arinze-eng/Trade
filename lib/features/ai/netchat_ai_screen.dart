import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/netchat_ai_service.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glass_container.dart';

/// [NEW 2026-09-02] "Netchat AI" — ask questions or upload files (images,
/// PDFs, text docs) and get answers from the PowerX agent.
class NetchatAiScreen extends StatefulWidget {
  const NetchatAiScreen({super.key});

  @override
  State<NetchatAiScreen> createState() => _NetchatAiScreenState();
}

class _AiMessage {
  final bool isUser;
  final String text;
  final List<String> attachments; // display names of attached files
  final bool isError;
  _AiMessage(this.isUser, this.text, {this.attachments = const [], this.isError = false});
}

class _NetchatAiScreenState extends State<NetchatAiScreen> {
  final _controller = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<_AiMessage> _messages = [];
  final List<File> _pendingFiles = [];
  bool _sending = false;

  // Conversation history sent to the model (text-only turns; file payloads
  // are re-sent once with their question then dropped to keep URLs sane).
  final List<Map<String, dynamic>> _history = [];

  static const int _maxHistoryTurns = 10;

  @override
  void dispose() {
    _controller.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.any);
    if (result == null || result.files.isEmpty) return;
    setState(() {
      for (final f in result.files) {
        if (f.path != null) _pendingFiles.add(File(f.path!));
      }
    });
  }

  void _removeFile(int i) => setState(() => _pendingFiles.removeAt(i));

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent + 120,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (_sending || (text.isEmpty && _pendingFiles.isEmpty)) return;

    final files = List<File>.from(_pendingFiles);
    setState(() {
      _sending = true;
      _controller.clear();
      _pendingFiles.clear();
      _messages.add(_AiMessage(
          true, text,
          attachments: files.map((f) => f.uri.pathSegments.last).toList()));
    });
    _scrollToBottom();

    try {
      final built = await NetchatAiService.buildFileParts(files);
      if (built.notes.isNotEmpty) {
        _messages.add(_AiMessage(false, built.notes.join('\n'), isError: true));
      }

      final answer = await NetchatAiService.ask(
        history: _history,
        userText: text,
        // Attachments ride along with the question they belong to.
        extraContentParts: built.parts,
        includeUserTextInContent: built.parts.isNotEmpty,
      );

      // Keep a lightweight text-only history for follow-up context.
      _history.add({
        'role': 'user',
        'content': text.isEmpty && files.isNotEmpty ? '[file analysis]' : text,
      });
      _history.add({'role': 'assistant', 'content': answer});
      while (_history.length > _maxHistoryTurns * 2) {
        _history.removeAt(0);
        _history.removeAt(0);
      }

      if (!mounted) return;
      setState(() => _messages.add(_AiMessage(false, answer)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _messages.add(_AiMessage(false, e.toString(), isError: true)));
    } finally {
      if (mounted) setState(() => _sending = false);
      _scrollToBottom();
    }
  }

  Widget _bubble(_AiMessage m) {
    final isMe = m.isUser;
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isMe
              ? const Color(0xFF6366F1)
              : (m.isError ? Colors.redAccent.withOpacity(0.15) : const Color(0xFF1F2B33)),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMe ? 16 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (m.attachments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: m.attachments
                      .map((a) => Chip(
                            label: Text(a, style: const TextStyle(fontSize: 11, color: Colors.white70)),
                            backgroundColor: Colors.black26,
                            visualDensity: VisualDensity.compact,
                          ))
                      .toList(),
                ),
              ),
            SelectableText(
              m.text,
              style: GoogleFonts.poppins(
                color: m.isError ? Colors.redAccent : Colors.white,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F1115),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                gradient: AppColors.accentGradient,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 10),
            Text('Netchat AI',
                style: GoogleFonts.sora(fontWeight: FontWeight.w800, color: Colors.white)),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? _buildWelcome()
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                    itemCount: _messages.length + (_sending ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i == _messages.length) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [
                              const SizedBox(width: 8),
                              const CircularProgressIndicator(strokeWidth: 2),
                              const SizedBox(width: 12),
                              Text('Thinking…',
                                  style: GoogleFonts.poppins(color: Colors.white54, fontSize: 13)),
                            ],
                          ),
                        );
                      }
                      return _bubble(_messages[i]);
                    },
                  ),
          ),
          if (_pendingFiles.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: _pendingFiles.asMap().entries.map((e) {
                  final name = e.value.uri.pathSegments.last;
                  return InputChip(
                    label: Text(name, style: const TextStyle(fontSize: 12)),
                    onDeleted: () => _removeFile(e.key),
                    deleteIcon: const Icon(Icons.close_rounded, size: 16),
                  );
                }).toList(),
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
              child: Row(
                children: [
                  IconButton.filledTonal(
                    onPressed: _pickFiles,
                    icon: const Icon(Icons.attach_file_rounded),
                    tooltip: 'Attach image / PDF / ZIP / text file',
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: GlassContainer(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: TextField(
                        controller: _controller,
                        minLines: 1,
                        maxLines: 4,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        decoration: const InputDecoration(
                          hintText: 'Ask Netchat AI anything…',
                          hintStyle: TextStyle(color: Colors.white30, fontSize: 14),
                          border: InputBorder.none,
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FloatingActionButton(
                    heroTag: 'ai_send',
                    mini: true,
                    onPressed: _sending ? null : _send,
                    backgroundColor: const Color(0xFF6366F1),
                    child: _sending
                        ? const SizedBox(
                            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.send_rounded, color: Colors.white, size: 18),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWelcome() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: AppColors.accentGradient,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.smart_toy_rounded, color: Colors.white, size: 40),
            ),
            const SizedBox(height: 18),
            Text('Netchat AI',
                style: GoogleFonts.sora(
                    color: Colors.white, fontWeight: FontWeight.w800, fontSize: 22)),
            const SizedBox(height: 8),
            Text(
              'Ask questions, translate, summarise, code, or attach files:\n'
              'images 🖼️, PDFs 📄, ZIPs 📦 and text documents 📝 are analysed instantly.',
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(color: Colors.white60, fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 22),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: ['Summarise this article', 'Translate to Igbo', 'Write a CV bullet', 'Explain like I am 5']
                  .map((s) => ActionChip(
                        label: Text(s, style: const TextStyle(fontSize: 12, color: Colors.white70)),
                        onPressed: () {
                          _controller.text = s;
                          _send();
                        },
                      ))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}
