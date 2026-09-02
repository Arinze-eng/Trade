import { useStore } from '../store';
import { Bell, Lock, HelpCircle, LogOut } from 'lucide-react';
import './ProfilePage.css';

export default function ProfilePage() {
  const { user, darkMode, toggleDarkMode } = useStore();

  return (
    <div className="page profile-page">
      <div className="profile-header">
        <img src={user.avatar} alt={user.name} className="profile-avatar" />
        <div className="profile-info">
          <h1>{user.name}</h1>
          <p className="profile-handle">{user.username}</p>
          {user.verified && <span className="verified-badge">✓ Verified Account</span>}
        </div>
      </div>

      <div className="profile-stats">
        <div className="stat">
          <span className="stat-value">₦{user.balance.toLocaleString()}</span>
          <span className="stat-label">Total Balance</span>
        </div>
        <div className="stat">
          <span className="stat-value">{user.streak}</span>
          <span className="stat-label">Day Streak</span>
        </div>
        <div className="stat">
          <span className="stat-value">{user.referrals}</span>
          <span className="stat-label">Referrals</span>
        </div>
      </div>

      <div className="profile-section">
        <h3>Account Settings</h3>
        {[
          { icon: Bell, label: 'Notifications', description: 'Manage alerts and updates' },
          { icon: Lock, label: 'Security', description: 'Password and authentication' },
          { icon: HelpCircle, label: 'Help & Support', description: 'Get help or report issues' },
        ].map((item, index) => (
          <button key={index} className="setting-item">
            <item.icon size={20} />
            <div className="setting-info">
              <p className="setting-label">{item.label}</p>
              <p className="setting-description">{item.description}</p>
            </div>
            <span className="chevron">›</span>
          </button>
        ))}
      </div>

      <div className="profile-section">
        <h3>Preferences</h3>

        <div className="preference-item">
          <div>
            <p className="preference-label">Dark Mode</p>
          </div>
          <input
            type="checkbox"
            checked={darkMode}
            onChange={toggleDarkMode}
            className="toggle"
          />
        </div>
      </div>

      <button className="logout-button">
        <LogOut size={20} />
        <span>Log Out</span>
      </button>

      <div className="profile-footer">
        <p>CDN CHAT v1.0.0</p>
        <p>© 2026 CDN CHAT. All rights reserved.</p>
      </div>
    </div>
  );
}
