import { Link } from 'react-router-dom';
import { useStore } from '../store';
import { TrendingUp, Flame, Users, ArrowUpRight, Download } from 'lucide-react';
import './WalletPage.css';

export default function WalletPage() {
  const { user, transactions } = useStore();

  return (
    <div className="page wallet-page">
      <div className="page-header">
        <h1>Wallet</h1>
      </div>

      <div className="balance-card">
        <div className="balance-header">
          <span>Total Balance</span>
          <span className="balance-amount">₦{user.balance.toLocaleString()}</span>
        </div>
        <div className="balance-subtext">Available for cash out</div>
      </div>

      <div className="stats-grid">
        <div className="stat-card">
          <div className="stat-icon earning">
            <TrendingUp size={24} />
          </div>
          <div className="stat-info">
            <p className="stat-label">Today\'s Earnings</p>
            <p className="stat-value">₦{user.dailyEarnings}</p>
          </div>
        </div>

        <div className="stat-card">
          <div className="stat-icon streak">
            <Flame size={24} />
          </div>
          <div className="stat-info">
            <p className="stat-label">Day Streak</p>
            <p className="stat-value">{user.streak} days</p>
          </div>
        </div>

        <div className="stat-card">
          <div className="stat-icon referral">
            <Users size={24} />
          </div>
          <div className="stat-info">
            <p className="stat-label">Referrals</p>
            <p className="stat-value">{user.referrals}</p>
          </div>
        </div>
      </div>

      <div className="action-buttons">
        <Link to="/wallet/cashout" className="action-button primary">
          <Download size={20} />
          <span>Cash Out</span>
        </Link>
        <button className="action-button secondary">
          <ArrowUpRight size={20} />
          <span>Transfer</span>
        </button>
      </div>

      <div className="transactions-section">
        <h3>Recent Transactions</h3>
        <div className="transactions-list">
          {transactions.map((transaction) => (
            <div key={transaction.id} className="transaction-item">
              <div className="transaction-info">
                <p className="transaction-type">{transaction.type}</p>
                <p className="transaction-time">{transaction.timestamp}</p>
              </div>
              <div className="transaction-amount">
                <span className={`amount ${transaction.status}`}>
                  +₦{transaction.amount}
                </span>
                <span className={`status ${transaction.status}`}>
                  {transaction.status === 'completed' ? '✓' : '⏳'}
                </span>
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
