import { useState } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { useStore } from '../store';
import {
  ArrowLeft,
  Send,
  Phone,
  Video,
  Paperclip,
  Smile,
  Mic,
  MoreVertical,
  X,
  Download,
} from 'lucide-react';
import './ChatDetailPage.css';

interface Message {
  id: string;
  sender: 'user' | 'other';
  text?: string;
  type: 'text' | 'file' | 'sticker' | 'voice';
  timestamp: string;
  fileName?: string;
  fileSize?: string;
  stickerEmoji?: string;
}

export default function ChatDetailPage() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const { chats } = useStore();
  const [messageText, setMessageText] = useState('');
  const [messages, setMessages] = useState<Message[]>([
    {
      id: '1',
      sender: 'other',
      text: 'Hey! How are you?',
      type: 'text',
      timestamp: '10:15 AM',
    },
    {
      id: '2',
      sender: 'user',
      text: 'I am doing great! How about you?',
      type: 'text',
      timestamp: '10:16 AM',
    },
    {
      id: '3',
      sender: 'other',
      text: 'All good here!',
      type: 'text',
      timestamp: '10:17 AM',
    },
  ]);
  const [showEmojiPicker, setShowEmojiPicker] = useState(false);
  const [isRecording, setIsRecording] = useState(false);
  const [showCallModal, setShowCallModal] = useState<'voice' | 'video' | null>(null);
  const [callDuration, setCallDuration] = useState(0);

  const chat = chats.find((c) => c.id === id);

  const stickers = ['😀', '😂', '❤️', '🔥', '👍', '🎉', '😎', '🚀'];

  const handleSendMessage = () => {
    if (messageText.trim()) {
      const newMessage: Message = {
        id: String(Date.now()),
        sender: 'user',
        text: messageText,
        type: 'text',
        timestamp: new Date().toLocaleTimeString([], {
          hour: '2-digit',
          minute: '2-digit',
        }),
      };
      setMessages([...messages, newMessage]);
      setMessageText('');
      setShowEmojiPicker(false);
    }
  };

  const handleAddSticker = (emoji: string) => {
    const newMessage: Message = {
      id: String(Date.now()),
      sender: 'user',
      type: 'sticker',
      stickerEmoji: emoji,
      timestamp: new Date().toLocaleTimeString([], {
        hour: '2-digit',
        minute: '2-digit',
      }),
    };
    setMessages([...messages, newMessage]);
    setShowEmojiPicker(false);
  };

  const handleFileUpload = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (file) {
      const newMessage: Message = {
        id: String(Date.now()),
        sender: 'user',
        type: 'file',
        fileName: file.name,
        fileSize: `${(file.size / 1024).toFixed(2)} KB`,
        timestamp: new Date().toLocaleTimeString([], {
          hour: '2-digit',
          minute: '2-digit',
        }),
      };
      setMessages([...messages, newMessage]);
    }
  };

  const handleVoiceRecord = () => {
    if (!isRecording) {
      setIsRecording(true);
    } else {
      const newMessage: Message = {
        id: String(Date.now()),
        sender: 'user',
        type: 'voice',
        timestamp: new Date().toLocaleTimeString([], {
          hour: '2-digit',
          minute: '2-digit',
        }),
      };
      setMessages([...messages, newMessage]);
      setIsRecording(false);
    }
  };

  const startCall = (type: 'voice' | 'video') => {
    setShowCallModal(type);
    setCallDuration(0);
    const interval = setInterval(() => {
      setCallDuration((prev) => prev + 1);
    }, 1000);
    return () => clearInterval(interval);
  };

  const endCall = () => {
    setShowCallModal(null);
    setCallDuration(0);
  };

  const formatCallDuration = (seconds: number) => {
    const mins = Math.floor(seconds / 60);
    const secs = seconds % 60;
    return `${mins}:${secs.toString().padStart(2, '0')}`;
  };

  if (!chat) {
    return (
      <div className="page chat-detail-page">
        <div className="chat-header-bar">
          <button className="back-button" onClick={() => navigate('/')}>
            <ArrowLeft size={24} />
          </button>
          <h1>Chat not found</h1>
        </div>
      </div>
    );
  }

  return (
    <div className="page chat-detail-page">
      {/* Header */}
      <div className="telegram-header">
        <button className="back-button" onClick={() => navigate('/')}>
          <ArrowLeft size={24} />
        </button>
        <div className="chat-header-info">
          <img src={chat.avatar} alt={chat.name} className="chat-avatar" />
          <div className="header-text">
            <h1>{chat.name}</h1>
            <p className="header-status">{chat.isOnline ? 'Online' : 'Offline'}</p>
          </div>
        </div>
        <div className="header-actions">
          <button
            className="call-button voice-call"
            onClick={() => startCall('voice')}
            title="Voice Call"
          >
            <Phone size={20} />
          </button>
          <button
            className="call-button video-call"
            onClick={() => startCall('video')}
            title="Video Call"
          >
            <Video size={20} />
          </button>
          <button className="more-button">
            <MoreVertical size={20} />
          </button>
        </div>
      </div>

      {/* Messages Container */}
      <div className="messages-container">
        {messages.map((msg) => (
          <div key={msg.id} className={`message-group ${msg.sender}`}>
            {msg.type === 'text' && (
              <div className="message-bubble text-message">
                <p>{msg.text}</p>
                <span className="message-time">{msg.timestamp}</span>
              </div>
            )}
            {msg.type === 'sticker' && (
              <div className="message-bubble sticker-message">
                <span className="sticker">{msg.stickerEmoji}</span>
                <span className="message-time">{msg.timestamp}</span>
              </div>
            )}
            {msg.type === 'file' && (
              <div className="message-bubble file-message">
                <div className="file-content">
                  <Paperclip size={20} />
                  <div className="file-info">
                    <p className="file-name">{msg.fileName}</p>
                    <p className="file-size">{msg.fileSize}</p>
                  </div>
                  <Download size={18} />
                </div>
                <span className="message-time">{msg.timestamp}</span>
              </div>
            )}
            {msg.type === 'voice' && (
              <div className="message-bubble voice-message">
                <div className="voice-content">
                  <button className="play-button">▶</button>
                  <div className="voice-wave">
                    <div className="wave"></div>
                    <div className="wave"></div>
                    <div className="wave"></div>
                    <div className="wave"></div>
                  </div>
                  <span className="voice-duration">0:15</span>
                </div>
                <span className="message-time">{msg.timestamp}</span>
              </div>
            )}
          </div>
        ))}
      </div>

      {/* Input Area */}
      <div className="telegram-input-area">
        <div className="input-wrapper">
          {!isRecording ? (
            <>
              <input
                type="text"
                placeholder="Message..."
                value={messageText}
                onChange={(e) => setMessageText(e.target.value)}
                onKeyPress={(e) => {
                  if (e.key === 'Enter' && !e.shiftKey) {
                    e.preventDefault();
                    handleSendMessage();
                  }
                }}
                className="message-input"
              />
              <div className="input-actions">
                <button
                  className="action-button emoji-button"
                  onClick={() => setShowEmojiPicker(!showEmojiPicker)}
                  title="Emoji & Stickers"
                >
                  <Smile size={20} />
                </button>
                <label className="action-button file-button" title="Send File">
                  <Paperclip size={20} />
                  <input
                    type="file"
                    onChange={handleFileUpload}
                    style={{ display: 'none' }}
                  />
                </label>
                <button
                  className="action-button voice-button"
                  onClick={handleVoiceRecord}
                  title="Record Voice Message"
                >
                  <Mic size={20} />
                </button>
              </div>
            </>
          ) : (
            <div className="recording-indicator">
              <div className="recording-dot"></div>
              <span>Recording...</span>
            </div>
          )}
        </div>
        <button
          className="send-button"
          onClick={isRecording ? handleVoiceRecord : handleSendMessage}
          disabled={!messageText.trim() && !isRecording}
        >
          {isRecording ? <X size={20} /> : <Send size={20} />}
        </button>
      </div>

      {/* Emoji/Sticker Picker */}
      {showEmojiPicker && (
        <div className="emoji-picker">
          <div className="emoji-header">
            <h3>Stickers</h3>
            <button onClick={() => setShowEmojiPicker(false)}>
              <X size={20} />
            </button>
          </div>
          <div className="stickers-grid">
            {stickers.map((emoji, idx) => (
              <button
                key={idx}
                className="sticker-button"
                onClick={() => handleAddSticker(emoji)}
              >
                {emoji}
              </button>
            ))}
          </div>
        </div>
      )}

      {/* Call Modal */}
      {showCallModal && (
        <div className="call-modal-overlay">
          <div className="call-modal">
            <div className="call-header">
              <img src={chat.avatar} alt={chat.name} className="call-avatar" />
              <div className="call-info">
                <h2>{chat.name}</h2>
                <p className="call-type">
                  {showCallModal === 'voice' ? 'Voice Call' : 'Video Call'}
                </p>
                <p className="call-duration">{formatCallDuration(callDuration)}</p>
              </div>
            </div>
            <div className="call-actions">
              <button className="call-action mute-button" title="Mute">
                <Mic size={24} />
              </button>
              <button className="call-action speaker-button" title="Speaker">
                <Phone size={24} />
              </button>
              <button className="call-action end-button" onClick={endCall} title="End Call">
                <Phone size={24} />
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
