import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useStore } from '../store';
import { Search, Plus } from 'lucide-react';
import SettingsMenu from '../components/SettingsMenu';
import './ChatsPage.css';

export default function ChatsPage() {
  const { chats } = useStore();
  const [searchQuery, setSearchQuery] = useState('');

  const filteredChats = chats.filter((chat) =>
    chat.name.toLowerCase().includes(searchQuery.toLowerCase())
  );

  return (
    <div className="page chats-page">
      <div className="page-header">
        <div>
          <h1>Chats</h1>
        </div>
        <div className="header-actions">
          <button className="icon-button">
            <Plus size={24} />
          </button>
          <SettingsMenu />
        </div>
      </div>

      <div className="search-container">
        <Search size={20} />
        <input
          type="text"
          placeholder="Search chats..."
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
        />
      </div>

      <div className="chats-list">
        {filteredChats.map((chat) => (
          <Link key={chat.id} to={`/chat/${chat.id}`} className="chat-item">
            <div className="avatar-container">
              <img src={chat.avatar} alt={chat.name} className="avatar" />
              {chat.isOnline && <div className="online-indicator"></div>}
            </div>

            <div className="chat-info">
              <div className="chat-header">
                <span className="chat-name">{chat.name}</span>
                <span className="timestamp">{chat.timestamp}</span>
              </div>
              <p className="last-message">{chat.lastMessage}</p>
            </div>

            {chat.unread > 0 && (
              <div className="unread-badge">{chat.unread}</div>
            )}
          </Link>
        ))}
      </div>
    </div>
  );
}
