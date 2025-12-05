cat > ~/bounce_en0.sh << 'EOF'
#!/bin/zsh

export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

echo "=== BEFORE: en0 ==="
ifconfig en0 | grep "inet " || echo "no inet on en0"

# Safety watchdog: if for some reason it doesn't come back, try again after 20s
( sleep 20 && sudo -n ifconfig en0 up ) &

echo "=== Bringing en0 DOWN ==="
sudo -n ifconfig en0 down

sleep 5

echo "=== Bringing en0 UP ==="
sudo -n ifconfig en0 up

echo "=== AFTER: en0 ==="
ifconfig en0 | grep "inet " || echo "no inet on en0"

echo "=== DONE ==="
EOF

chmod +x ~/bounce_en0.sh