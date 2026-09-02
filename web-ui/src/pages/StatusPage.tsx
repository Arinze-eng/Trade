import { Link } from 'react-router-dom';
import { useStore } from '../store';
import { Plus, Eye, TrendingUp } from 'lucide-react';
import './StatusPage.css';

export default function StatusPage() {
  const { statuses } = useStore();

  return (
    <div className="page status-page">
      <div className="page-header">
        <h1>Status Feed</h1>
        <Link to="/status/create" className="create-button">
          <Plus size={24} />
          <span>Create</span>
        </Link>
      </div>

      <div className="statuses-grid">
        {statuses.map((status) => (
          <div key={status.id} className="status-card">
            <div className="status-image">
              <img src={status.image} alt={status.caption} />
              <div className="status-overlay"></div>
            </div>

            <div className="status-content">
              <div className="status-user">
                <img src={status.avatar} alt={status.username} className="status-avatar" />
                <div>
                  <p className="status-username">{status.username}</p>
                  <p className="status-time">{status.timestamp}</p>
                </div>
              </div>

              <p className="status-caption">{status.caption}</p>

              <div className="status-stats">
                <div className="stat">
                  <Eye size={16} />
                  <span>{status.views} views</span>
                </div>
                <div className="stat earning">
                  <TrendingUp size={16} />
                  <span>₦{status.earnings.toFixed(2)}</span>
                </div>
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
