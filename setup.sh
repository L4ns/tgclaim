#!/bin/bash
set -e

REPO_BASE="https://raw.githubusercontent.com/L4ns/tgclaim/main"

echo "=== Membuat folder struktur project Telegram NFT Claim ==="
mkdir -p telegram-nft-claim/{backend/api,backend/db,backend/abis,frontend/pages,contracts}
cd telegram-nft-claim

# Download backend files
curl -s $REPO_BASE/backend/api/bind-wallet.js -o backend/api/bind-wallet.js
curl -s $REPO_BASE/backend/api/claim-nft.js -o backend/api/claim-nft.js
curl -s $REPO_BASE/backend/server.js -o backend/server.js
curl -s $REPO_BASE/backend/abis/NFTContract.json -o backend/abis/NFTContract.json
echo '{}' > backend/db/bindings.json
echo '{}' > backend/db/claimed.json

# Download frontend
curl -s $REPO_BASE/frontend/pages/index.tsx -o frontend/pages/index.tsx

# Download contracts
curl -s $REPO_BASE/contracts/TelegramNFTProof.sol -o contracts/TelegramNFTProof.sol
curl -s $REPO_BASE/contracts/IVLayerVerifier.sol -o contracts/IVLayerVerifier.sol

# Download .env.example
curl -s $REPO_BASE/backend/.env.example -o backend/.env.example

echo "=== Install dependencies backend ==="
cd backend
npm init -y
npm install express body-parser ethers dotenv
cd ..

echo "=== Install dependencies frontend ==="
cd frontend
npx create-next-app@latest . --ts --use-npm --no-git --no-install
npm install
cd ..

echo "=== Instalasi selesai ==="
echo ""
echo "Langkah selanjutnya:"
echo "- Edit backend/.env sesuai kebutuhan (lihat backend/.env.example)"
echo "- Deploy backend (misal: node backend/server.js atau deploy ke Render/Heroku/VPS)"
echo "- Deploy frontend (frontend/) ke Vercel"
echo "- Deploy contract di contracts/"
echo "- Selesai!"
