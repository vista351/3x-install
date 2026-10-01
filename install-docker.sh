#!/bin/bash

set -e

echo "[1/7] Removing old packages Docker..."
sudo apt-get remove -y docker docker-engine docker.io containerd runc || true

echo "[2/7] Обновление системы..."
sudo apt-get update
sudo apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

echo "[3/7] Add GPG-key Docker..."
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "[4/7] Add repository Docker..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "[5/7] Installing Docker..."
sudo apt-get update
sudo apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

echo "[6/7] Startup and autostart Docker..."
sudo systemctl enable docker
sudo systemctl start docker

echo "[7/7] Adding the current user to a group docker..."
sudo usermod -aG docker $USER

echo
echo "Docker installed."
echo "Checking version:"
echo "docker --version"
echo
echo "To apply docker group permissions, run:"
echo "newgrp docker"
echo "or log out."