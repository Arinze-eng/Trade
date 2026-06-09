import { Link, useLocation } from 'react-router-dom';
import { MessageCircle, Image, Wallet, Hash, User } from 'lucide-react';
import './Layout.css';

interface LayoutProps {
  children: React.ReactNode;
}

export default function Layout({ children }: LayoutProps) {
  const location = useLocation();

  // Hide bottom nav when viewing chat details
  const isInChat = location.pathname.startsWith('/chat/');

  const isActive = (path: string) => location.pathname === path || location.pathname.startsWith(path + '/');

  return (
    <div className={`app-container ${isInChat ? 'chat-view' : ''}`}>
      <div className="main-content">
        {children}
      </div>

      <nav className={`bottom-nav ${isInChat ? 'hidden' : ''}`}>
        <Link
          to="/"
          className={`nav-item ${isActive('/') && location.pathname === '/' ? 'active' : ''}`}
        >
          <MessageCircle size={24} />
          <span>Chats</span>
        </Link>

        <Link
          to="/status"
          className={`nav-item ${isActive('/status') ? 'active' : ''}`}
        >
          <Image size={24} />
          <span>Status</span>
        </Link>

        <Link
          to="/wallet"
          className={`nav-item ${isActive('/wallet') ? 'active' : ''}`}
        >
          <Wallet size={24} />
          <span>Wallet</span>
        </Link>

        <Link
          to="/channels"
          className={`nav-item ${isActive('/channels') ? 'active' : ''}`}
        >
          <Hash size={24} />
          <span>Channels</span>
        </Link>

        <Link
          to="/profile"
          className={`nav-item ${isActive('/profile') ? 'active' : ''}`}
        >
          <User size={24} />
          <span>Profile</span>
        </Link>
      </nav>
    </div>
  );
}
