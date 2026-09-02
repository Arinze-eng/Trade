import { useState, useRef, useEffect } from 'react';
import { useStore } from '../store';
import {
  MoreVertical,
  User,
  Shield,
  HardDrive,
  Bell,
  Download,
  HelpCircle,
  LogOut,
} from 'lucide-react';
import './SettingsMenu.css';

export default function SettingsMenu() {
  const [isOpen, setIsOpen] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);
  const { user, darkMode, toggleDarkMode } = useStore();

  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(event.target as Node)) {
        setIsOpen(false);
      }
    };

    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  const menuItems = [
    { icon: User, label: 'Profile', action: 'profile' },
    { icon: Shield, label: 'Account & Security', action: 'security' },
    { icon: Bell, label: 'Notifications', action: 'notifications' },
    { icon: HardDrive, label: 'Backup & Restore', action: 'backup' },
    { icon: Download, label: 'Export Data', action: 'export' },
    { icon: HelpCircle, label: 'Help & Support', action: 'help' },
  ];

  const handleMenuAction = (action: string) => {
    console.log(`Action: ${action}`);
    setIsOpen(false);
  };

  return (
    <div className="settings-menu-container" ref={menuRef}>
      <button
        className="settings-menu-button"
        onClick={() => setIsOpen(!isOpen)}
        title="More options"
      >
        <MoreVertical size={24} />
      </button>

      {isOpen && (
        <div className="settings-dropdown">
          <div className="settings-header">
            <img src={user.avatar} alt={user.name} className="settings-avatar" />
            <div className="settings-user-info">
              <p className="settings-user-name">{user.name}</p>
              <p className="settings-user-handle">{user.username}</p>
            </div>
          </div>

          <div className="settings-divider"></div>

          <div className="settings-items">
            {menuItems.map((item) => (
              <button
                key={item.action}
                className="settings-item"
                onClick={() => handleMenuAction(item.action)}
              >
                <item.icon size={18} />
                <span>{item.label}</span>
              </button>
            ))}
          </div>

          <div className="settings-divider"></div>

          <div className="settings-footer">
            <label className="dark-mode-toggle">
              <input
                type="checkbox"
                checked={darkMode}
                onChange={toggleDarkMode}
              />
              <span>Dark Mode</span>
            </label>
          </div>

          <div className="settings-divider"></div>

          <button className="settings-logout">
            <LogOut size={18} />
            <span>Log Out</span>
          </button>
        </div>
      )}
    </div>
  );
}
