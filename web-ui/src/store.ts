import { create } from 'zustand';

export interface User {
  id: string;
  name: string;
  username: string;
  avatar: string;
  balance: number;
  dailyEarnings: number;
  streak: number;
  referrals: number;
  verified: boolean;
}

export interface Chat {
  id: string;
  name: string;
  avatar: string;
  lastMessage: string;
  timestamp: string;
  unread: number;
  isOnline: boolean;
}

export interface Message {
  id: string;
  sender: 'user' | 'other';
  text: string;
  timestamp: string;
}

export interface Status {
  id: string;
  username: string;
  avatar: string;
  image: string;
  caption: string;
  views: number;
  timestamp: string;
  earnings: number;
}

export interface Channel {
  id: string;
  name: string;
  icon: string;
  members: number;
  description: string;
  isFeatured: boolean;
  isSponsored: boolean;
  isJoined: boolean;
}

export interface Transaction {
  id: string;
  type: string;
  amount: number;
  timestamp: string;
  status: 'completed' | 'pending';
}

interface AppStore {
  user: User;
  chats: Chat[];
  statuses: Status[];
  channels: Channel[];
  transactions: Transaction[];
  messages: Record<string, Message[]>;
  darkMode: boolean;
  
  // User actions
  updateUserBalance: (amount: number) => void;
  updateDailyEarnings: (amount: number) => void;
  updateStreak: (days: number) => void;
  
  // Chat actions
  addMessage: (chatId: string, message: Message) => void;
  getMessages: (chatId: string) => Message[];
  
  // Status actions
  addStatus: (status: Status) => void;
  updateStatusViews: (statusId: string, views: number) => void;
  
  // Channel actions
  toggleChannelJoin: (channelId: string) => void;
  
  // Transaction actions
  addTransaction: (transaction: Transaction) => void;
  
  // Theme actions
  toggleDarkMode: () => void;
  setDarkMode: (isDark: boolean) => void;
}

const initialUser: User = {
  id: '1',
  name: 'Oladimeji Alex',
  username: '@oladimeji_alex',
  avatar: 'https://api.dicebear.com/7.x/avataaars/svg?seed=User',
  balance: 3375,
  dailyEarnings: 1250,
  streak: 7,
  referrals: 12,
  verified: true,
};

const initialChats: Chat[] = [
  {
    id: '1',
    name: 'Priya Sharma',
    avatar: 'https://api.dicebear.com/7.x/avataaars/svg?seed=Priya',
    lastMessage: 'Thanks! I\'ll review it.',
    timestamp: '10:24 AM',
    unread: 2,
    isOnline: true,
  },
  {
    id: '2',
    name: 'Rahul Mehta',
    avatar: 'https://api.dicebear.com/7.x/avataaars/svg?seed=Rahul',
    lastMessage: 'Sounds good',
    timestamp: 'Yesterday',
    unread: 1,
    isOnline: false,
  },
  {
    id: '3',
    name: 'Neha Kapoor',
    avatar: 'https://api.dicebear.com/7.x/avataaars/svg?seed=Neha',
    lastMessage: 'Shared a document',
    timestamp: 'Tue',
    unread: 0,
    isOnline: true,
  },
];

const initialStatuses: Status[] = [
  {
    id: '1',
    username: 'GreatJohn',
    avatar: 'https://api.dicebear.com/7.x/avataaars/svg?seed=John',
    image: 'https://images.unsplash.com/photo-1507003211169-0a1dd7228f2d?w=400&h=300&fit=crop',
    caption: 'Morning views 🌅 Grateful for another beautiful day.',
    views: 128,
    timestamp: '2h ago',
    earnings: 320,
  },
  {
    id: '2',
    username: 'Ada_oxo',
    avatar: 'https://api.dicebear.com/7.x/avataaars/svg?seed=Ada',
    image: 'https://images.unsplash.com/photo-1506794778202-cad84cf45f1d?w=400&h=300&fit=crop',
    caption: 'Small steps Big future. Keep saving. Keep growing.',
    views: 210,
    timestamp: '5h ago',
    earnings: 525,
  },
];

const initialChannels: Channel[] = [
  {
    id: '1',
    name: 'Stock Market Talk',
    icon: '📈',
    members: 128000,
    description: 'Real conversations about stocks, markets, and investing strategies.',
    isFeatured: false,
    isSponsored: false,
    isJoined: true,
  },
  {
    id: '2',
    name: 'Personal Finance 101',
    icon: '💰',
    members: 89000,
    description: 'Budgeting, saving, debt payoff, building wealth step by step.',
    isFeatured: false,
    isSponsored: false,
    isJoined: true,
  },
  {
    id: '3',
    name: 'Fintech & AI Innovators',
    icon: '🤖',
    members: 42000,
    description: 'Exploring the future of fintech, blockchain, and AI in finance.',
    isFeatured: true,
    isSponsored: true,
    isJoined: false,
  },
];

const initialTransactions: Transaction[] = [
  {
    id: '1',
    type: 'Status Views',
    amount: 320,
    timestamp: 'Today, 9:41 AM',
    status: 'completed',
  },
  {
    id: '2',
    type: 'Messages Sent',
    amount: 187.5,
    timestamp: 'Today, 8:15 AM',
    status: 'completed',
  },
  {
    id: '3',
    type: 'Daily Streak Bonus',
    amount: 20,
    timestamp: 'Today, 12:00 AM',
    status: 'completed',
  },
];

export const useStore = create<AppStore>((set, get) => ({
  user: initialUser,
  chats: initialChats,
  statuses: initialStatuses,
  channels: initialChannels,
  transactions: initialTransactions,
  darkMode: localStorage.getItem('darkMode') === 'true',
  messages: {
    '1': [
      { id: '1', sender: 'other', text: 'Hi, just checking in on the Q2 financial report.', timestamp: '10:18 AM' },
      { id: '2', sender: 'user', text: 'Sure, I\'ll review it and get back to you.', timestamp: '10:19 AM' },
      { id: '3', sender: 'other', text: 'Thanks! I\'ll review it.', timestamp: '10:24 AM' },
    ],
    '2': [],
    '3': [],
  },

  updateUserBalance: (amount) =>
    set((state) => ({
      user: { ...state.user, balance: state.user.balance + amount },
    })),

  updateDailyEarnings: (amount) =>
    set((state) => ({
      user: { ...state.user, dailyEarnings: state.user.dailyEarnings + amount },
    })),

  updateStreak: (days) =>
    set((state) => ({
      user: { ...state.user, streak: days },
    })),

  addMessage: (chatId, message) =>
    set((state) => ({
      messages: {
        ...state.messages,
        [chatId]: [...(state.messages[chatId] || []), message],
      },
    })),

  getMessages: (chatId) => {
    const state = get();
    return state.messages[chatId] || [];
  },

  addStatus: (status) =>
    set((state) => ({
      statuses: [status, ...state.statuses],
    })),

  updateStatusViews: (statusId, views) =>
    set((state) => ({
      statuses: state.statuses.map((s) =>
        s.id === statusId ? { ...s, views, earnings: views * 2.5 } : s
      ),
    })),

  toggleChannelJoin: (channelId) =>
    set((state) => ({
      channels: state.channels.map((c) =>
        c.id === channelId ? { ...c, isJoined: !c.isJoined } : c
      ),
    })),

  addTransaction: (transaction) =>
    set((state) => ({
      transactions: [transaction, ...state.transactions],
    })),

  toggleDarkMode: () =>
    set((state) => {
      const newDarkMode = !state.darkMode;
      localStorage.setItem('darkMode', String(newDarkMode));
      return { darkMode: newDarkMode };
    }),

  setDarkMode: (isDark) => {
    localStorage.setItem('darkMode', String(isDark));
    set({ darkMode: isDark });
  },
}));
