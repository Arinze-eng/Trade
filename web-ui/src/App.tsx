import { BrowserRouter as Router, Routes, Route } from 'react-router-dom';
import { useEffect } from 'react';
import { useStore } from './store';
import Layout from './components/Layout';
import ChatsPage from './pages/ChatsPage';
import StatusPage from './pages/StatusPage';
import WalletPage from './pages/WalletPage';
import ChannelsPage from './pages/ChannelsPage';
import ProfilePage from './pages/ProfilePage';
import ChatDetailPage from './pages/ChatDetailPage';
import CreateStatusPage from './pages/CreateStatusPage';
import CashOutPage from './pages/CashOutPage';
import './App.css';

function App() {
  const { darkMode } = useStore();

  useEffect(() => {
    if (darkMode) {
      document.documentElement.classList.add('dark');
    } else {
      document.documentElement.classList.remove('dark');
    }
  }, [darkMode]);

  return (
    <Router>
      <Layout>
        <Routes>
          <Route path="/" element={<ChatsPage />} />
          <Route path="/status" element={<StatusPage />} />
          <Route path="/status/create" element={<CreateStatusPage />} />
          <Route path="/wallet" element={<WalletPage />} />
          <Route path="/wallet/cashout" element={<CashOutPage />} />
          <Route path="/channels" element={<ChannelsPage />} />
          <Route path="/profile" element={<ProfilePage />} />
          <Route path="/chat/:id" element={<ChatDetailPage />} />
        </Routes>
      </Layout>
    </Router>
  );
}

export default App;
