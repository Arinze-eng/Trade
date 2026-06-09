import { useStore } from '../store';
import { Users, MessageCircle } from 'lucide-react';
import './ChannelsPage.css';

export default function ChannelsPage() {
  const { channels, toggleChannelJoin } = useStore();

  const featuredChannels = channels.filter((c) => c.isFeatured);
  const joinedChannels = channels.filter((c) => c.isJoined);
  const otherChannels = channels.filter((c) => !c.isFeatured && !c.isJoined);

  return (
    <div className="page channels-page">
      <div className="page-header">
        <h1>Channels</h1>
      </div>

      {featuredChannels.length > 0 && (
        <div className="channels-section">
          <h3>Featured Channels</h3>
          <div className="channels-list">
            {featuredChannels.map((channel) => (
              <div key={channel.id} className="channel-card featured">
                <div className="channel-header">
                  <span className="channel-icon">{channel.icon}</span>
                  <div className="channel-info">
                    <h4>{channel.name}</h4>
                    <p>{channel.description}</p>
                  </div>
                  {channel.isSponsored && <span className="sponsored-badge">Sponsored</span>}
                </div>
                <div className="channel-footer">
                  <div className="channel-members">
                    <Users size={16} />
                    <span>{channel.members.toLocaleString()}</span>
                  </div>
                  <button
                    className={`join-button ${channel.isJoined ? 'joined' : ''}`}
                    onClick={() => toggleChannelJoin(channel.id)}
                  >
                    {channel.isJoined ? 'Joined' : 'Join'}
                  </button>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      {joinedChannels.length > 0 && (
        <div className="channels-section">
          <h3>Your Channels</h3>
          <div className="channels-list">
            {joinedChannels.map((channel) => (
              <div key={channel.id} className="channel-card">
                <div className="channel-header">
                  <span className="channel-icon">{channel.icon}</span>
                  <div className="channel-info">
                    <h4>{channel.name}</h4>
                    <p>{channel.description}</p>
                  </div>
                </div>
                <div className="channel-footer">
                  <div className="channel-members">
                    <Users size={16} />
                    <span>{channel.members.toLocaleString()}</span>
                  </div>
                  <button className="action-button">
                    <MessageCircle size={16} />
                    <span>Open</span>
                  </button>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      {otherChannels.length > 0 && (
        <div className="channels-section">
          <h3>Discover Channels</h3>
          <div className="channels-list">
            {otherChannels.map((channel) => (
              <div key={channel.id} className="channel-card">
                <div className="channel-header">
                  <span className="channel-icon">{channel.icon}</span>
                  <div className="channel-info">
                    <h4>{channel.name}</h4>
                    <p>{channel.description}</p>
                  </div>
                </div>
                <div className="channel-footer">
                  <div className="channel-members">
                    <Users size={16} />
                    <span>{channel.members.toLocaleString()}</span>
                  </div>
                  <button
                    className="join-button"
                    onClick={() => toggleChannelJoin(channel.id)}
                  >
                    Join
                  </button>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
