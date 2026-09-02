import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useStore } from '../store';
import { ArrowLeft, Zap, Clock } from 'lucide-react';
import './CreateStatusPage.css';

const SAMPLE_IMAGES = [
  'https://images.unsplash.com/photo-1507003211169-0a1dd7228f2d?w=400&h=300&fit=crop',
  'https://images.unsplash.com/photo-1506794778202-cad84cf45f1d?w=400&h=300&fit=crop',
  'https://images.unsplash.com/photo-1507842217343-583f20270319?w=400&h=300&fit=crop',
];

export default function CreateStatusPage() {
  const navigate = useNavigate();
  const { addStatus, updateUserBalance } = useStore();
  const [caption, setCaption] = useState('');
  const [selectedImage, setSelectedImage] = useState(SAMPLE_IMAGES[0]);

  const handlePublish = () => {
    if (caption.trim()) {
      const newStatus = {
        id: String(Date.now()),
        username: 'You',
        avatar: 'https://api.dicebear.com/7.x/avataaars/svg?seed=User',
        image: selectedImage,
        caption,
        views: 0,
        timestamp: 'now',
        earnings: 0,
      };

      addStatus(newStatus);
      updateUserBalance(50); // Bonus for creating status
      navigate('/status');
    }
  };

  return (
    <div className="page create-status-page">
      <div className="create-header">
        <button className="back-button" onClick={() => navigate('/status')}>
          <ArrowLeft size={24} />
        </button>
        <h1>Create Status</h1>
        <div style={{ width: 24 }}></div>
      </div>

      <div className="create-preview">
        <img src={selectedImage} alt="Preview" />
        <div className="caption-overlay">
          <textarea
            placeholder="Add a caption..."
            value={caption}
            onChange={(e) => setCaption(e.target.value)}
            maxLength={200}
          />
          <span className="char-count">{caption.length}/200</span>
        </div>
      </div>

      <div className="create-section">
        <h3>Select Image</h3>
        <div className="image-options">
          {SAMPLE_IMAGES.map((image) => (
            <button
              key={image}
              className={`image-option ${selectedImage === image ? 'selected' : ''}`}
              onClick={() => setSelectedImage(image)}
            >
              <img src={image} alt="Option" />
            </button>
          ))}
        </div>
      </div>

      <div className="create-section">
        <h3>Earning Potential</h3>
        <div className="earning-card">
          <div className="earning-row">
            <span>Per View</span>
            <span className="earning-amount">₦2.50</span>
          </div>
          <div className="earning-row">
            <span>Estimated (100 views)</span>
            <span className="earning-amount">₦250</span>
          </div>
        </div>
      </div>

      <div className="create-section">
        <h3>Options</h3>
        <button className="option-button">
          <Zap size={20} />
          <div>
            <div className="option-label">Boost This Status</div>
            <div className="option-description">₦3,000 for 1,000 extra views</div>
          </div>
        </button>
        <button className="option-button">
          <Clock size={20} />
          <div>
            <div className="option-label">Schedule Status</div>
            <div className="option-description">Post at a specific time</div>
          </div>
        </button>
      </div>

      <div className="create-actions">
        <button className="publish-button" onClick={handlePublish}>
          Publish Status
        </button>
        <button className="cancel-button" onClick={() => navigate('/status')}>
          Cancel
        </button>
      </div>
    </div>
  );
}
