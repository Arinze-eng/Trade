import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useStore } from '../store';
import { ArrowLeft, Clock } from 'lucide-react';
import './CashOutPage.css';

const WITHDRAWAL_METHODS = [
  { id: '1', name: 'OPay', icon: '💳', last4: '1234', isDefault: true },
  { id: '2', name: 'MTN MoMo', icon: '📱', last4: '5678', isDefault: false },
  { id: '3', name: 'Zenith Bank', icon: '🏦', last4: '9012', isDefault: false },
];

export default function CashOutPage() {
  const navigate = useNavigate();
  const { user, updateUserBalance, addTransaction } = useStore();
  const [amount, setAmount] = useState('');
  const [selectedMethod, setSelectedMethod] = useState('1');
  const [showConfirm, setShowConfirm] = useState(false);

  const handleCashOut = () => {
    const cashOutAmount = parseInt(amount);
    if (amount && cashOutAmount >= 5000 && cashOutAmount <= user.balance) {
      setShowConfirm(true);
    } else if (cashOutAmount < 5000) {
      alert('Minimum cash out amount is ₦5,000');
    } else if (cashOutAmount > user.balance) {
      alert('Insufficient balance');
    }
  };

  const confirmCashOut = () => {
    const cashOutAmount = parseInt(amount);
    updateUserBalance(-cashOutAmount);
    addTransaction({
      id: String(Date.now()),
      type: 'Cash Out',
      amount: cashOutAmount,
      timestamp: new Date().toLocaleString(),
      status: 'pending',
    });
    alert(`Cash out of ₦${amount} initiated! You\'ll receive it within 24 hours.`);
    navigate('/wallet');
  };

  if (showConfirm) {
    return (
      <div className="page cashout-page">
        <div className="confirm-card">
          <div className="confirm-icon">✓</div>
          <h2>Confirm Cash Out</h2>
          <p className="confirm-amount">₦{amount}</p>

          <div className="confirm-details">
            <div className="detail-row">
              <span>Amount</span>
              <span>₦{amount}</span>
            </div>
            <div className="detail-row">
              <span>Processing Fee</span>
              <span>Free</span>
            </div>
            <div className="detail-row total">
              <span>You\'ll Receive</span>
              <span>₦{amount}</span>
            </div>
          </div>

          <button className="confirm-button" onClick={confirmCashOut}>
            Confirm & Send
          </button>
          <button className="cancel-button" onClick={() => setShowConfirm(false)}>
            Cancel
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="page cashout-page">
      <div className="cashout-header">
        <button className="back-button" onClick={() => navigate('/wallet')}>
          <ArrowLeft size={24} />
        </button>
        <h1>Cash Out</h1>
        <div style={{ width: 24 }}></div>
      </div>

      <div className="cashout-section">
        <h3>Enter Amount</h3>
        <div className="amount-input-container">
          <span className="currency">₦</span>
          <input
            type="number"
            placeholder="0"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
          />
        </div>
        <p className="amount-note">Minimum: ₦5,000 • Maximum: ₦50,000/day</p>
      </div>

      <div className="cashout-section">
        <h3>Select Withdrawal Method</h3>
        {WITHDRAWAL_METHODS.map((method) => (
          <button
            key={method.id}
            className={`method-card ${selectedMethod === method.id ? 'selected' : ''}`}
            onClick={() => setSelectedMethod(method.id)}
          >
            <div className="method-left">
              <span className="method-icon">{method.icon}</span>
              <div>
                <p className="method-name">{method.name}</p>
                <p className="method-last4">•••• {method.last4}</p>
                {method.isDefault && <span className="default-badge">Default</span>}
              </div>
            </div>
            <div className={`radio ${selectedMethod === method.id ? 'selected' : ''}`}>
              {selectedMethod === method.id && <div className="radio-inner"></div>}
            </div>
          </button>
        ))}
      </div>

      <div className="cashout-section">
        <h3>Processing Time</h3>
        <div className="info-card">
          <Clock size={20} />
          <div>
            <p className="info-title">Usually within 24 hours</p>
            <p className="info-description">
              Most cash outs are processed within 24 hours. Some may take up to 48 hours.
            </p>
          </div>
        </div>
      </div>

      <div className="cashout-actions">
        <button
          className="cashout-button"
          onClick={handleCashOut}
          disabled={!amount}
        >
          Cash Out ₦{amount || '0'}
        </button>
      </div>
    </div>
  );
}
