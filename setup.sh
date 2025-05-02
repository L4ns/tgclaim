#!/bin/bash
set -e

echo "=== Membuat folder struktur project Telegram NFT Claim ==="
mkdir -p telegram-nft-claim/{backend/api,backend/db,backend/abis,frontend/pages,contracts}
cd telegram-nft-claim

echo "=== Membuat backend/api/bind-wallet.js ==="
cat <<'EOF' > backend/api/bind-wallet.js
const express = require("express");
const crypto = require("crypto");
const fs = require("fs");

const BINDINGS_DB = "./db/bindings.json";
const BOT_TOKEN = process.env.TELEGRAM_BOT_TOKEN;

function makeInitDataString(data) {
  return Object.keys(data)
    .filter((k) => k !== "hash")
    .sort()
    .map((k) => `${k}=${data[k]}`)
    .join("\n");
}

function checkTelegramSignature({ initData, botToken, hash }) {
  const secret = crypto.createHash("sha256").update(botToken).digest();
  const hmac = crypto.createHmac("sha256", secret).update(initData).digest("hex");
  return hmac === hash;
}

const router = express.Router();

router.post("/bind-wallet", (req, res) => {
  const { telegram_id, username, first_name, hash, wallet } = req.body;
  if (!telegram_id || !hash || !wallet) return res.status(400).json({ error: "Missing data" });

  // Validasi signature Telegram
  const initData = { id: telegram_id, username, first_name };
  const initDataString = makeInitDataString(initData);
  if (!checkTelegramSignature({ initData: initDataString, botToken: BOT_TOKEN, hash })) {
    return res.status(401).json({ error: "Invalid Telegram signature" });
  }

  // Simpan binding (DB/file/production DB)
  let bindings = {};
  if (fs.existsSync(BINDINGS_DB)) {
    bindings = JSON.parse(fs.readFileSync(BINDINGS_DB, "utf8"));
  }
  bindings[telegram_id] = { telegram_id, username, wallet };
  fs.writeFileSync(BINDINGS_DB, JSON.stringify(bindings, null, 2));
  return res.json({ success: true });
});

module.exports = router;
EOF

echo "=== Membuat backend/api/claim-nft.js ==="
cat <<'EOF' > backend/api/claim-nft.js
const express = require("express");
const crypto = require("crypto");
const fs = require("fs");
const { execSync } = require("child_process");
const { ethers } = require("ethers");

const BINDINGS_DB = "./db/bindings.json";
const CLAIMED_DB = "./db/claimed.json";
const BOT_TOKEN = process.env.TELEGRAM_BOT_TOKEN;
const NFT_CONTRACT = process.env.NFT_CONTRACT;
const RELAYER_PK = process.env.RELAYER_PK;
const VERIFIER_ABI = require("../abis/NFTContract.json").abi;

function makeInitDataString(data) {
  return Object.keys(data)
    .filter((k) => k !== "hash")
    .sort()
    .map((k) => `${k}=${data[k]}`)
    .join("\n");
}
function checkTelegramSignature({ initData, botToken, hash }) {
  const secret = crypto.createHash("sha256").update(botToken).digest();
  const hmac = crypto.createHmac("sha256", secret).update(initData).digest("hex");
  return hmac === hash;
}

// Utility: atomic claim mark (file-based, atomic for single process)
function markClaimed(telegram_id) {
  let claimed = {};
  if (fs.existsSync(CLAIMED_DB)) claimed = JSON.parse(fs.readFileSync(CLAIMED_DB, "utf8"));
  if (claimed[telegram_id]) return false;
  claimed[telegram_id] = { claimed_at: Date.now() };
  fs.writeFileSync(CLAIMED_DB, JSON.stringify(claimed, null, 2));
  return true;
}

const router = express.Router();
router.post("/claim-nft", async (req, res) => {
  const { telegram_id, username, first_name, hash } = req.body;
  if (!telegram_id || !hash) return res.status(400).json({ error: "Missing data" });

  // Validasi signature Telegram
  const initData = { id: telegram_id, username, first_name };
  const initDataString = makeInitDataString(initData);
  if (!checkTelegramSignature({ initData: initDataString, botToken: BOT_TOKEN, hash })) {
    return res.status(401).json({ error: "Invalid Telegram signature" });
  }

  // Cek binding
  if (!fs.existsSync(BINDINGS_DB)) return res.status(404).json({ error: "No binding found" });
  const bindings = JSON.parse(fs.readFileSync(BINDINGS_DB, "utf8"));
  const binding = bindings[telegram_id];
  if (!binding) return res.status(404).json({ error: "No wallet bound to this Telegram" });

  // ATOMIC: Cek & Mark claimed SEBELUM minting (prevent race/double claim)
  if (!markClaimed(telegram_id)) {
    return res.status(400).json({ error: "Already claimed" });
  }

  // Generate proof (Telegram <-> wallet)
  const payload = { telegram_id: binding.telegram_id, username: binding.username, wallet: binding.wallet };
  const payloadFile = `/tmp/payload-tg-wallet-${telegram_id}.json`;
  const proofFile = `/tmp/proof-tg-wallet-${telegram_id}.json`;
  fs.writeFileSync(payloadFile, JSON.stringify(payload, null, 2));

  try {
    execSync(`vlayer web-proof create --input ${payloadFile} --output ${proofFile}`);
    const proof = JSON.parse(fs.readFileSync(proofFile, "utf8"));

    // Mint NFT via relayer
    const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
    const relayer = new ethers.Wallet(RELAYER_PK, provider);
    const nft = new ethers.Contract(NFT_CONTRACT, VERIFIER_ABI, relayer);

    // Mint: mintWithTelegramProof(address to, uint256 telegram_id, string username, bytes proof)
    const tx = await nft.mintWithTelegramProof(
      binding.wallet,
      binding.telegram_id,
      binding.username,
      ethers.hexlify(Buffer.from(JSON.stringify(proof)))
    );
    await tx.wait();

    return res.json({ success: true, wallet: binding.wallet });
  } catch (e) {
    // Fallback: unmark claim so user can retry (or handle manual review)
    let claimed = {};
    if (fs.existsSync(CLAIMED_DB)) claimed = JSON.parse(fs.readFileSync(CLAIMED_DB, "utf8"));
    delete claimed[telegram_id];
    fs.writeFileSync(CLAIMED_DB, JSON.stringify(claimed, null, 2));
    return res.status(500).json({ error: "Failed to claim NFT", detail: e.message });
  }
});

module.exports = router;
EOF

echo "=== Membuat backend/server.js ==="
cat <<'EOF' > backend/server.js
const express = require("express");
const bodyParser = require("body-parser");
const bindWallet = require("./api/bind-wallet");
const claimNFT = require("./api/claim-nft");

const app = express();
app.use(bodyParser.json());
app.use("/api", bindWallet);
app.use("/api", claimNFT);

const PORT = process.env.PORT || 4000;
app.listen(PORT, () => console.log("Backend running on", PORT));
EOF

echo "=== Membuat backend/abis/NFTContract.json (dummy ABI) ==="
cat <<'EOF' > backend/abis/NFTContract.json
{
  "abi": [
    {
      "inputs": [
        {"internalType":"address","name":"to","type":"address"},
        {"internalType":"uint256","name":"telegram_id","type":"uint256"},
        {"internalType":"string","name":"username","type":"string"},
        {"internalType":"bytes","name":"proof","type":"bytes"}
      ],
      "name":"mintWithTelegramProof",
      "outputs":[],
      "stateMutability":"nonpayable",
      "type":"function"
    }
  ]
}
EOF

echo "=== Membuat backend/db/bindings.json dan claimed.json ==="
echo '{}' > backend/db/bindings.json
echo '{}' > backend/db/claimed.json

echo "=== Membuat backend/.env.example ==="
cat <<'EOF' > backend/.env.example
TELEGRAM_BOT_TOKEN=isi_token_bot_father
NFT_CONTRACT=0xAlamatContractNFT
RELAYER_PK=privatekey_wallet_minter
RPC_URL=https://sepolia.infura.io/v3/xxxx
EOF

echo "=== Membuat backend/package.json ==="
cat <<'EOF' > backend/package.json
{
  "name": "telegram-nft-backend",
  "version": "1.0.0",
  "main": "server.js",
  "type": "commonjs",
  "scripts": {
    "start": "node server.js",
    "dev": "nodemon server.js"
  },
  "dependencies": {
    "body-parser": "^1.20.2",
    "crypto": "^1.0.1",
    "dotenv": "^16.4.5",
    "ethers": "^6.10.0",
    "express": "^4.19.2"
  },
  "devDependencies": {
    "nodemon": "^3.1.0"
  }
}
EOF

echo "=== Membuat frontend/pages/index.tsx ==="
cat <<'EOF' > frontend/pages/index.tsx
import { useState, useEffect } from "react";

function getTelegramUserData() {
  if (typeof window !== "undefined" && window.Telegram && window.Telegram.WebApp) {
    return window.Telegram.WebApp.initDataUnsafe;
  }
  return null;
}

export default function Home() {
  const [telegram, setTelegram] = useState<any>(null);
  const [wallet, setWallet] = useState("");
  const [bindStatus, setBindStatus] = useState("");
  const [claimStatus, setClaimStatus] = useState("");
  const [claimedAddress, setClaimedAddress] = useState("");

  useEffect(() => {
    setTelegram(getTelegramUserData());
  }, []);

  const handleBindWallet = async () => {
    setBindStatus("Processing...");
    const res = await fetch("/api/bind-wallet", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        telegram_id: telegram.id,
        username: telegram.username,
        first_name: telegram.first_name,
        hash: telegram.hash,
        wallet,
      }),
    });
    const data = await res.json();
    if (data.success) setBindStatus("Wallet bound successfully!");
    else setBindStatus("Failed: " + (data.error || "Unknown error"));
  };

  const handleClaimNFT = async () => {
    setClaimStatus("Claiming...");
    const res = await fetch("/api/claim-nft", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        telegram_id: telegram.id,
        username: telegram.username,
        first_name: telegram.first_name,
        hash: telegram.hash,
      }),
    });
    const data = await res.json();
    if (data.success) {
      setClaimStatus("NFT sent to your wallet! Check your address.");
      setClaimedAddress(data.wallet);
    } else {
      setClaimStatus("Failed: " + (data.error || "Unknown error"));
    }
  };

  return (
    <main style={{ maxWidth: 600, margin: "auto", padding: 32 }}>
      <h1>Claim Your Telegram NFT!</h1>
      <div>
        <p>Telegram Username: <b>{telegram?.username}</b></p>
        <input
          placeholder="Your wallet address (0x...)"
          value={wallet}
          onChange={e => setWallet(e.target.value)}
        />
        <button onClick={handleBindWallet} disabled={!telegram || !wallet}>
          Bind Wallet
        </button>
        <div>{bindStatus}</div>
      </div>
      <hr />
      <button onClick={handleClaimNFT} disabled={!telegram}>
        Claim NFT to Bound Wallet
      </button>
      <div style={{ marginTop: 16, color: "green" }}>{claimStatus}</div>
      {claimedAddress && (
        <div style={{ fontSize: 14 }}>
          NFT sent to: <b>{claimedAddress}</b>
        </div>
      )}
    </main>
  );
}
EOF

echo "=== Membuat frontend/package.json ==="
cat <<'EOF' > frontend/package.json
{
  "name": "telegram-nft-frontend",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "dev": "next dev",
    "build": "next build",
    "start": "next start"
  },
  "dependencies": {
    "next": "^14.2.0",
    "react": "^18.2.0",
    "react-dom": "^18.2.0"
  },
  "devDependencies": {
    "@types/node": "^20.10.5",
    "@types/react": "^18.2.37",
    "@types/react-dom": "^18.2.15",
    "typescript": "^5.4.5"
  }
}
EOF

echo "=== Membuat frontend/tsconfig.json ==="
cat <<'EOF' > frontend/tsconfig.json
{
  "compilerOptions": {
    "target": "es5",
    "lib": ["dom", "dom.iterable", "esnext"],
    "allowJs": true,
    "skipLibCheck": true,
    "strict": false,
    "forceConsistentCasingInFileNames": true,
    "noEmit": true,
    "esModuleInterop": true,
    "module": "esnext",
    "moduleResolution": "node",
    "resolveJsonModule": true,
    "isolatedModules": true,
    "jsx": "preserve"
  },
  "include": ["next-env.d.ts", "**/*.ts", "**/*.tsx"],
  "exclude": ["node_modules"]
}
EOF

echo "=== Membuat frontend/next.config.js ==="
cat <<'EOF' > frontend/next.config.js
/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: false
}
module.exports = nextConfig
EOF

echo "=== Membuat contracts/TelegramNFTProof.sol ==="
cat <<'EOF' > contracts/TelegramNFTProof.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVLayerVerifier {
    function verifyProof(bytes calldata proof, bytes32 publicInput) external view returns (bool);
}

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract TelegramNFTProof is ERC721, Ownable {
    IVLayerVerifier public verifier;
    mapping(uint256 => bool) public telegramIdClaimed;

    event NFTClaimed(uint256 telegram_id, address wallet);

    constructor(address verifierAddress) ERC721("TelegramNFT", "TG-NFT") {
        verifier = IVLayerVerifier(verifierAddress);
    }

    function mintWithTelegramProof(
        address to,
        uint256 telegram_id,
        string calldata username,
        bytes calldata proof
    ) external onlyOwner {
        require(!telegramIdClaimed[telegram_id], "Already claimed");
        bytes32 publicInput = keccak256(abi.encodePacked(telegram_id, username, to));
        require(verifier.verifyProof(proof, publicInput), "Invalid proof");
        telegramIdClaimed[telegram_id] = true;
        _safeMint(to, telegram_id);
        emit NFTClaimed(telegram_id, to);
    }
}
EOF

echo "=== Membuat contracts/IVLayerVerifier.sol ==="
cat <<'EOF' > contracts/IVLayerVerifier.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
interface IVLayerVerifier {
    function verifyProof(bytes calldata proof, bytes32 publicInput) external view returns (bool);
}
EOF

echo "=== Install dependencies backend ==="
cd backend
npm install
cd ..

echo "=== Install dependencies frontend ==="
cd frontend
npm install
cd ..

echo "=== Instalasi selesai ==="
echo ""
echo "Langkah selanjutnya:"
echo "- Edit backend/.env sesuai kebutuhan (lihat backend/.env.example)"
echo "- Jalankan backend: cd backend && npm run dev"
echo "- Jalankan frontend: cd frontend && npm run dev"
echo "- Deploy frontend ke Vercel jika mau"
echo "- Deploy contract di contracts/"
echo "- Selesai!"
