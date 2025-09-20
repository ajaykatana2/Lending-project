// Replace ABI with your contract's ABI
const contractABI = [
    // Example methods, replace with your contract's actual ABI
    "function depositCollateral(uint256 amount) external",
    "function borrow(uint256 amount) external",
    "function repayLoan(uint256 amount) external",
    "function withdrawCollateral(uint256 amount) external",
    "function getUserCollateral(address user) view returns (uint256)"
];
const contractAddress = "0xc9f5ca2c36ddcc22cf5c71b1ff32a28486934ace";

let provider;
let signer;
let contract;
let userAddress;

async function connectWallet() {
    if (window.ethereum) {
        await window.ethereum.request({ method: 'eth_requestAccounts' });
        provider = new ethers.providers.Web3Provider(window.ethereum);
        signer = provider.getSigner();
        userAddress = await signer.getAddress();
        contract = new ethers.Contract(contractAddress, contractABI, signer);
        document.getElementById('accountDisplay').innerText = "Connected: " + userAddress;
    } else {
        alert('MetaMask or compatible wallet required!');
    }
}

document.getElementById('connectButton').onclick = connectWallet;

async function viewCollateral() {
    if (!contract || !userAddress) return;
    try {
        const collateral = await contract.getUserCollateral(userAddress);
        document.getElementById('collateralDisplay').innerText = "Collateral: " + ethers.utils.formatUnits(collateral, 18);
    } catch (e) {
        document.getElementById('collateralDisplay').innerText = "Unable to fetch collateral";
    }
}
document.getElementById('viewCollateral').onclick = viewCollateral;

async function depositCollateral() {
    const amount = document.getElementById('depositAmount').value;
    if (!amount || !contract) return;
    try {
        const tx = await contract.depositCollateral(ethers.utils.parseUnits(amount, 18));
        document.getElementById('depositStatus').innerText = "Depositing...";
        await tx.wait();
        document.getElementById('depositStatus').innerText = "Deposit successful!";
    } catch (e) {
        document.getElementById('depositStatus').innerText = "Deposit failed!";
    }
}
document.getElementById('depositButton').onclick = depositCollateral;

async function borrow() {
    const amount = document.getElementById('borrowAmount').value;
    if (!amount || !contract) return;
    try {
        const tx = await contract.borrow(ethers.utils.parseUnits(amount, 18));
        document.getElementById('borrowStatus').innerText = "Borrowing...";
        await tx.wait();
        document.getElementById('borrowStatus').innerText = "Borrow successful!";
    } catch (e) {
        document.getElementById('borrowStatus').innerText = "Borrow failed!";
    }
}
document.getElementById('borrowButton').onclick = borrow;

async function repayLoan() {
    const amount = document.getElementById('repayAmount').value;
    if (!amount || !contract) return;
    try {
        const tx = await contract.repayLoan(ethers.utils.parseUnits(amount, 18));
        document.getElementById('repayStatus').innerText = "Repaying...";
        await tx.wait();
        document.getElementById('repayStatus').innerText = "Repay successful!";
    } catch (e) {
        document.getElementById('repayStatus').innerText = "Repay failed!";
    }
}
document.getElementById('repayButton').onclick = repayLoan;

async function withdrawCollateral() {
    const amount = document.getElementById('withdrawAmount').value;
    if (!amount || !contract) return;
    try {
        const tx = await contract.withdrawCollateral(ethers.utils.parseUnits(amount, 18));
        document.getElementById('withdrawStatus').innerText = "Withdrawing...";
        await tx.wait();
        document.getElementById('withdrawStatus').innerText = "Withdraw successful!";
    } catch (e) {
        document.getElementById('withdrawStatus').innerText = "Withdraw failed!";
    }
}
document.getElementById('withdrawButton').onclick = withdrawCollateral;
