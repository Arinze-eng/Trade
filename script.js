// Trading Website JavaScript
class TradingApp {
    constructor() {
        this.currentSymbol = 'AAPL';
        this.currentPrice = 150.25;
        this.chartData = [];
        this.watchlistData = [
            { symbol: 'AAPL', price: 150.25, change: 2.15 },
            { symbol: 'GOOGL', price: 2845.30, change: -1.25 },
            { symbol: 'MSFT', price: 335.80, change: 0.85 },
            { symbol: 'TSLA', price: 245.60, change: 3.20 },
            { symbol: 'AMZN', price: 3125.45, change: -0.65 }
        ];
        this.init();
    }

    init() {
        this.setupEventListeners();
        this.initializeChart();
        this.startRealTimeUpdates();
        this.updateWatchlist();
        this.setupTradingForm();
    }

    setupEventListeners() {
        // Tab switching
        document.querySelectorAll('.tab-btn').forEach(btn => {
            btn.addEventListener('click', (e) => this.switchTab(e.target.dataset.tab));
        });

        // Timeframe buttons
        document.querySelectorAll('.timeframe-btn').forEach(btn => {
            btn.addEventListener('click', (e) => this.changeTimeframe(e.target));
        });

        // Chart type buttons
        document.querySelectorAll('.chart-type-btn').forEach(btn => {
            btn.addEventListener('click', (e) => this.changeChartType(e.target));
        });

        // Watchlist item clicks
        document.querySelectorAll('.watchlist-item').forEach(item => {
            item.addEventListener('click', (e) => this.selectSymbol(e.currentTarget));
        });

        // Search functionality
        const searchInput = document.getElementById('symbolSearch');
        searchInput.addEventListener('input', (e) => this.searchSymbols(e.target.value));

        // Order type change
        const orderTypeSelect = document.getElementById('orderType');
        orderTypeSelect.addEventListener('change', (e) => this.handleOrderTypeChange(e.target.value));

        // Quantity input
        const quantityInput = document.getElementById('quantity');
        quantityInput.addEventListener('input', (e) => this.updateEstimatedCost(e.target.value));

        // Chart mouse events
        const chartCanvas = document.getElementById('tradingChart');
        chartCanvas.addEventListener('mousemove', (e) => this.handleChartMouseMove(e));
        chartCanvas.addEventListener('mouseleave', () => this.hideTooltip());

        // News modal
        document.querySelectorAll('.nav-item').forEach(item => {
            if (item.textContent === 'News') {
                item.addEventListener('click', (e) => {
                    e.preventDefault();
                    this.showNewsModal();
                });
            }
        });
    }

    switchTab(tab) {
        // Update active tab
        document.querySelectorAll('.tab-btn').forEach(btn => btn.classList.remove('active'));
        document.querySelector(`[data-tab="${tab}"]`).classList.add('active');

        // Show/hide forms
        document.getElementById('buyForm').style.display = tab === 'buy' ? 'block' : 'none';
        document.getElementById('sellForm').style.display = tab === 'sell' ? 'block' : 'none';
    }

    changeTimeframe(button) {
        document.querySelectorAll('.timeframe-btn').forEach(btn => btn.classList.remove('active'));
        button.classList.add('active');
        this.generateChartData(button.textContent);
        this.updateChart();
    }

    changeChartType(button) {
        document.querySelectorAll('.chart-type-btn').forEach(btn => btn.classList.remove('active'));
        button.classList.add('active');
        this.updateChart();
    }

    selectSymbol(item) {
        const symbol = item.querySelector('.symbol').textContent;
        const price = parseFloat(item.querySelector('.price').textContent.replace('$', ''));
        
        this.currentSymbol = symbol;
        this.currentPrice = price;
        
        // Update UI
        document.querySelector('.current-symbol').textContent = symbol;
        document.querySelector('.current-price').textContent = `$${price.toFixed(2)}`;
        
        // Update trading buttons
        document.querySelector('.btn-buy').textContent = `Buy ${symbol}`;
        document.querySelector('.btn-sell').textContent = `Sell ${symbol}`;
        
        // Generate new chart data
        this.generateChartData('1W');
        this.updateChart();
        
        // Highlight selected item
        document.querySelectorAll('.watchlist-item').forEach(i => i.classList.remove('selected'));
        item.classList.add('selected');
    }

    searchSymbols(query) {
        if (query.length < 2) return;
        
        // Simulate search results
        const mockResults = ['AAPL', 'GOOGL', 'MSFT', 'TSLA', 'AMZN', 'NVDA', 'META', 'NFLX'];
        const filtered = mockResults.filter(symbol => 
            symbol.toLowerCase().includes(query.toLowerCase())
        );
        
        // You could implement a dropdown here to show results
        console.log('Search results:', filtered);
    }

    handleOrderTypeChange(orderType) {
        const limitPriceGroup = document.querySelector('.limit-price');
        if (orderType === 'limit') {
            limitPriceGroup.style.display = 'block';
        } else {
            limitPriceGroup.style.display = 'none';
        }
    }

    updateEstimatedCost(quantity) {
        const cost = (parseFloat(quantity) || 0) * this.currentPrice;
        document.querySelector('.estimated-cost').textContent = `$${cost.toFixed(2)}`;
    }

    initializeChart() {
        const canvas = document.getElementById('tradingChart');
        this.ctx = canvas.getContext('2d');
        
        // Set canvas size
        const resizeCanvas = () => {
            const rect = canvas.parentElement.getBoundingClientRect();
            canvas.width = rect.width;
            canvas.height = rect.height;
            this.updateChart();
        };
        
        resizeCanvas();
        window.addEventListener('resize', resizeCanvas);
        
        // Generate initial data
        this.generateChartData('1W');
        this.updateChart();
    }

    generateChartData(timeframe) {
        const dataPoints = {
            '1D': 24,
            '1W': 7 * 24,
            '1M': 30,
            '3M': 90,
            '1Y': 365,
            '5Y': 365 * 5
        };
        
        const points = dataPoints[timeframe] || 168;
        this.chartData = [];
        
        let price = this.currentPrice;
        const now = new Date();
        
        for (let i = points; i >= 0; i--) {
            const date = new Date(now.getTime() - i * 60 * 60 * 1000);
            const volatility = 0.02;
            const change = (Math.random() - 0.5) * volatility * price;
            price = Math.max(price + change, price * 0.8);
            
            this.chartData.push({
                time: date,
                price: price,
                volume: Math.random() * 1000000
            });
        }
    }

    updateChart() {
        if (!this.ctx || this.chartData.length === 0) return;
        
        const canvas = this.ctx.canvas;
        const width = canvas.width;
        const height = canvas.height;
        
        // Clear canvas
        this.ctx.fillStyle = '#131722';
        this.ctx.fillRect(0, 0, width, height);
        
        // Draw grid
        this.drawGrid(width, height);
        
        // Draw price line
        this.drawPriceLine(width, height);
        
        // Draw volume bars
        this.drawVolume(width, height);
        
        // Draw price labels
        this.drawPriceLabels(width, height);
    }

    drawGrid(width, height) {
        this.ctx.strokeStyle = '#2a2e39';
        this.ctx.lineWidth = 1;
        
        // Horizontal lines
        for (let i = 0; i <= 10; i++) {
            const y = (height / 10) * i;
            this.ctx.beginPath();
            this.ctx.moveTo(0, y);
            this.ctx.lineTo(width, y);
            this.ctx.stroke();
        }
        
        // Vertical lines
        for (let i = 0; i <= 10; i++) {
            const x = (width / 10) * i;
            this.ctx.beginPath();
            this.ctx.moveTo(x, 0);
            this.ctx.lineTo(x, height);
            this.ctx.stroke();
        }
    }

    drawPriceLine(width, height) {
        if (this.chartData.length < 2) return;
        
        const prices = this.chartData.map(d => d.price);
        const minPrice = Math.min(...prices);
        const maxPrice = Math.max(...prices);
        const priceRange = maxPrice - minPrice;
        
        this.ctx.strokeStyle = '#2962ff';
        this.ctx.lineWidth = 2;
        this.ctx.beginPath();
        
        this.chartData.forEach((point, index) => {
            const x = (index / (this.chartData.length - 1)) * width;
            const y = height - ((point.price - minPrice) / priceRange) * height;
            
            if (index === 0) {
                this.ctx.moveTo(x, y);
            } else {
                this.ctx.lineTo(x, y);
            }
        });
        
        this.ctx.stroke();
        
        // Fill area under line
        this.ctx.fillStyle = 'rgba(41, 98, 255, 0.1)';
        this.ctx.lineTo(width, height);
        this.ctx.lineTo(0, height);
        this.ctx.closePath();
        this.ctx.fill();
    }

    drawVolume(width, height) {
        const volumeHeight = height * 0.2;
        const volumes = this.chartData.map(d => d.volume);
        const maxVolume = Math.max(...volumes);
        
        this.ctx.fillStyle = '#434651';
        
        this.chartData.forEach((point, index) => {
            const x = (index / (this.chartData.length - 1)) * width;
            const barHeight = (point.volume / maxVolume) * volumeHeight;
            const y = height - barHeight;
            const barWidth = width / this.chartData.length;
            
            this.ctx.fillRect(x - barWidth / 2, y, barWidth * 0.8, barHeight);
        });
    }

    drawPriceLabels(width, height) {
        const prices = this.chartData.map(d => d.price);
        const minPrice = Math.min(...prices);
        const maxPrice = Math.max(...prices);
        
        this.ctx.fillStyle = '#787b86';
        this.ctx.font = '12px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto';
        this.ctx.textAlign = 'right';
        
        // Draw price labels on the right
        for (let i = 0; i <= 5; i++) {
            const price = minPrice + ((maxPrice - minPrice) / 5) * i;
            const y = height - (i / 5) * height;
            this.ctx.fillText(`$${price.toFixed(2)}`, width - 10, y + 4);
        }
    }

    handleChartMouseMove(event) {
        const canvas = event.target;
        const rect = canvas.getBoundingClientRect();
        const x = event.clientX - rect.left;
        const y = event.clientY - rect.top;
        
        // Calculate data point index
        const dataIndex = Math.floor((x / canvas.width) * this.chartData.length);
        
        if (dataIndex >= 0 && dataIndex < this.chartData.length) {
            const dataPoint = this.chartData[dataIndex];
            this.showTooltip(event.clientX, event.clientY, dataPoint);
        }
    }

    showTooltip(x, y, dataPoint) {
        const tooltip = document.getElementById('priceTooltip');
        tooltip.style.display = 'block';
        tooltip.style.left = `${x + 10}px`;
        tooltip.style.top = `${y - 30}px`;
        tooltip.innerHTML = `
            <div>Price: $${dataPoint.price.toFixed(2)}</div>
            <div>Time: ${dataPoint.time.toLocaleTimeString()}</div>
            <div>Volume: ${dataPoint.volume.toLocaleString()}</div>
        `;
    }

    hideTooltip() {
        const tooltip = document.getElementById('priceTooltip');
        tooltip.style.display = 'none';
    }

    startRealTimeUpdates() {
        setInterval(() => {
            this.updatePrices();
            this.updateWatchlist();
        }, 5000); // Update every 5 seconds
    }

    updatePrices() {
        // Simulate price changes
        this.watchlistData.forEach(item => {
            const change = (Math.random() - 0.5) * 0.02; // ±2% change
            item.price *= (1 + change);
            item.change = change * 100;
        });
        
        // Update current symbol price
        const currentItem = this.watchlistData.find(item => item.symbol === this.currentSymbol);
        if (currentItem) {
            this.currentPrice = currentItem.price;
            document.querySelector('.current-price').textContent = `$${this.currentPrice.toFixed(2)}`;
            
            const changeElement = document.querySelector('.price-change');
            const changeValue = currentItem.change;
            changeElement.textContent = `${changeValue >= 0 ? '+' : ''}$${(changeValue * this.currentPrice / 100).toFixed(2)} (${changeValue.toFixed(2)}%)`;
            changeElement.className = `price-change ${changeValue >= 0 ? 'positive' : 'negative'}`;
        }
    }

    updateWatchlist() {
        const watchlistElement = document.getElementById('watchlist');
        watchlistElement.innerHTML = '';
        
        this.watchlistData.forEach(item => {
            const itemElement = document.createElement('div');
            itemElement.className = 'watchlist-item';
            itemElement.innerHTML = `
                <div class="symbol">${item.symbol}</div>
                <div class="price">$${item.price.toFixed(2)}</div>
                <div class="change ${item.change >= 0 ? 'positive' : 'negative'}">
                    ${item.change >= 0 ? '+' : ''}${item.change.toFixed(2)}%
                </div>
            `;
            
            itemElement.addEventListener('click', () => this.selectSymbol(itemElement));
            watchlistElement.appendChild(itemElement);
        });
    }

    setupTradingForm() {
        // Buy button
        document.querySelector('.btn-buy').addEventListener('click', () => {
            const quantity = document.getElementById('quantity').value;
            if (quantity && quantity > 0) {
                this.executeTrade('buy', quantity);
            } else {
                alert('Please enter a valid quantity');
            }
        });
        
        // Sell button
        document.querySelector('.btn-sell').addEventListener('click', () => {
            const quantity = document.querySelector('#sellForm input[type="number"]').value;
            if (quantity && quantity > 0) {
                this.executeTrade('sell', quantity);
            } else {
                alert('Please enter a valid quantity');
            }
        });
    }

    executeTrade(type, quantity) {
        const orderType = document.getElementById('orderType').value;
        const price = orderType === 'market' ? this.currentPrice : 
                     parseFloat(document.getElementById('limitPrice').value) || this.currentPrice;
        
        // Simulate order execution
        const order = {
            symbol: this.currentSymbol,
            type: type,
            quantity: parseInt(quantity),
            price: price,
            orderType: orderType,
            status: Math.random() > 0.1 ? 'completed' : 'pending',
            timestamp: new Date()
        };
        
        // Add to recent orders (simulate)
        this.addRecentOrder(order);
        
        // Show confirmation
        alert(`${type.toUpperCase()} order for ${quantity} shares of ${this.currentSymbol} has been ${order.status}`);
        
        // Clear form
        document.getElementById('quantity').value = '';
        this.updateEstimatedCost(0);
    }

    addRecentOrder(order) {
        const ordersList = document.querySelector('.orders-list');
        const orderElement = document.createElement('div');
        orderElement.className = 'order-item';
        orderElement.innerHTML = `
            <div class="order-symbol">${order.symbol}</div>
            <div class="order-details">
                <div class="order-type">${order.type} ${order.quantity} shares</div>
                <div class="order-status ${order.status}">${order.status}</div>
            </div>
            <div class="order-price">$${(order.price * order.quantity).toFixed(2)}</div>
        `;
        
        ordersList.insertBefore(orderElement, ordersList.firstChild);
        
        // Keep only last 5 orders
        while (ordersList.children.length > 5) {
            ordersList.removeChild(ordersList.lastChild);
        }
    }

    showNewsModal() {
        document.getElementById('newsModal').style.display = 'block';
    }
}

// Modal functions
function closeModal() {
    document.getElementById('newsModal').style.display = 'none';
}

// Close modal when clicking outside
window.addEventListener('click', (event) => {
    const modal = document.getElementById('newsModal');
    if (event.target === modal) {
        modal.style.display = 'none';
    }
});

// Initialize the trading app when DOM is loaded
document.addEventListener('DOMContentLoaded', () => {
    window.tradingApp = new TradingApp();
});

// Additional utility functions
function formatNumber(num) {
    if (num >= 1000000) {
        return (num / 1000000).toFixed(1) + 'M';
    } else if (num >= 1000) {
        return (num / 1000).toFixed(1) + 'K';
    }
    return num.toString();
}

function formatCurrency(amount) {
    return new Intl.NumberFormat('en-US', {
        style: 'currency',
        currency: 'USD'
    }).format(amount);
}

// Keyboard shortcuts
document.addEventListener('keydown', (event) => {
    // ESC to close modal
    if (event.key === 'Escape') {
        closeModal();
    }
    
    // Ctrl/Cmd + K for search focus
    if ((event.ctrlKey || event.metaKey) && event.key === 'k') {
        event.preventDefault();
        document.getElementById('symbolSearch').focus();
    }
});

// Add some animation effects
function addPulseEffect(element) {
    element.classList.add('loading');
    setTimeout(() => {
        element.classList.remove('loading');
    }, 1000);
}

// Export for potential module usage
if (typeof module !== 'undefined' && module.exports) {
    module.exports = TradingApp;
}

