import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../local_db/local_chat_store.dart';
import 'chat_room_screen.dart';

class ArchivedChatsScreen extends StatefulWidget {
  final Map<String, dynamic> currentUser;
  final List<Map<String, dynamic>> threads;

  const ArchivedChatsScreen({
    super.key,
    required this.currentUser,
    required this.threads,
  });

  @override
  State<ArchivedChatsScreen> createState() => _ArchivedChatsScreenState();
}

class _ArchivedChatsScreenState extends State<ArchivedChatsScreen> {
  final _localChatStore = LocalChatStore();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F2027),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('Archived', style: GoogleFonts.poppins(fontWeight: FontWeight.w700)),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: widget.threads.length,
        itemBuilder: (context, index) {
          final t = widget.threads[index];
          final username = (t['other_username'] ?? t['username'] ?? '').toString();
          final displayName = (t['other_display_name'] ?? '').toString();
          final otherId = (t['other_user_id'] ?? t['other_id'] ?? '').toString();
          final lastMessage = (t['last_message'] ?? '').toString();

          return FutureBuilder(
            future: _localChatStore.getMeta(ownerUserId: widget.currentUser['id'], otherId: otherId),
            builder: (context, snap) {
              final meta = snap.data;
              final isArchived = meta?.isArchived == true;
              if (!isArchived) return const SizedBox.shrink();

              final letter = ((displayName.trim().isNotEmpty ? displayName : username).isNotEmpty)
                  ? (displayName.trim().isNotEmpty ? displayName : username)[0]
                  : '?';

              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  radius: 24,
                  backgroundColor: const Color(0xFF6366F1),
                  child: Text(letter, style: const TextStyle(color: Colors.white)),
                ),
                title: Text(
                  displayName.trim().isNotEmpty ? displayName : username,
                  style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  lastMessage,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(color: Colors.white60, fontSize: 12),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.unarchive_rounded, color: Colors.white70),
                  onPressed: () async {
                    await _localChatStore.setArchived(
                      ownerUserId: widget.currentUser['id'],
                      otherId: otherId,
                      archived: false,
                    );
                    if (mounted) setState(() {});
                  },
                ),
                onTap: () {
                  final otherUser = {
                    'id': otherId,
                    'username': t['other_username'] ?? t['username'],
                    'display_name': t['other_display_name'],
                    'email': t['other_email'] ?? t['email'],
                  };
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ChatRoomScreen(
                        otherUser: otherUser,
                        currentUser: widget.currentUser,
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
