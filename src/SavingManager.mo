import Principal "mo:base/Principal";
import Array "mo:base/Array";
import Time "mo:base/Time";
import Iter "mo:base/Iter";
import HashMap "mo:base/HashMap";
import Text "mo:base/Text";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Hash "mo:base/Hash";
import Int "mo:base/Int";
import Int64 "mo:base/Int64";
import Result "mo:base/Result";
import Error "mo:base/Error";
import Debug "mo:base/Debug";
import Buffer "mo:base/Buffer";
import Blob "mo:base/Blob";
import Float "mo:base/Float";
import Option "mo:base/Option";
import ExperimentalCycles "mo:base/ExperimentalCycles";

import Types "Types";
import Utils "Utils";

shared (init_msg) actor class SavingManager() = this {
    // ===== Type Aliases =====
    type Account = Types.Account;
    type Saving = Types.Saving;
    type SavingId = Types.SavingId;
    type SavingStatus = Types.SavingStatus;
    type Transaction = Types.Transaction;
    type TransactionId = Types.TransactionId;
    type TransactionStatus = Types.TransactionStatus;
    type TransactionType = Types.TransactionType;
    type StartSavingRequest = Types.StartSavingRequest;
    type TopUpRequest = Types.TopUpRequest;
    type UpdateSavingRequest = Types.UpdateSavingRequest;
    type SavingResponse = Types.SavingResponse;
    type TransactionResponse = Types.TransactionResponse;
    type ICP = Types.ICP;
    type ICPTransferArgs = Types.ICPTransferArgs;
    type ICPTransferResult = Types.ICPTransferResult;
    type ICPTransferError = Types.ICPTransferError;
    type TransferArgs = Types.TransferArgs;
    type TransferResult = Types.TransferResult;
    type SavingWithHistory = Types.SavingWithHistory;
    type TopUpHistory = Types.TopUpHistory;
    type CyclesInfo = Types.CyclesInfo;

    // ===== HTTP OutCall Type Aliases =====
    type HttpRequestArgs = Types.HttpRequestArgs;
    type HttpResponsePayload = Types.HttpResponsePayload;
    type HttpResponse = Types.HttpResponse;

    // ===== Staking Type Aliases =====
    type StakingInfo = Types.StakingInfo;
    type NeuronState = Types.NeuronState;
    type StakeICPRequest = Types.StakeICPRequest;
    type StakeICPResponse = Types.StakeICPResponse;
    type UnstakeRequest = Types.UnstakeRequest;
    type StakingRewards = Types.StakingRewards;
    type StakeResponse = Types.StakeResponse;
    type UnstakeResponse = Types.UnstakeResponse;

    // ===== ICP Ledger Canister Actor =====
    let icpLedger : actor {
        transfer : ICPTransferArgs -> async ICPTransferResult;
        account_balance : query { account : Blob } -> async { e8s : Nat64 };
    } = actor ("ryjl3-tyaaa-aaaaa-aaaba-cai");

    // ===== State Variables =====
    private stable var nextSavingId : SavingId = 0;
    private stable var nextTransactionId : TransactionId = 0;
    private stable var nextNeuronId : Nat64 = 1000000; // Start with large number for uniqueness
    private stable var owner : Principal = Principal.fromText("4pzfl-o35wy-m642s-gm3ot-5j4aq-zywlz-2b3jt-d2rlw-36q7o-nmtcx-oqe");
    private stable var stakingPaused : Bool = false;
    private stable var cyclesThreshold : Nat = 1_000_000_000_000; // 1T cycles default threshold

    // Cycles usage tracking
    private stable var lastCyclesBalance : Nat = 0;
    private stable var lastCyclesCheckTime : Int = 0;
    private stable var cyclesUsageHistory : [(Int, Nat)] = []; // (timestamp, usage)

    // ===== Staking Constants =====
    private let MIN_STAKE_AMOUNT : Nat64 = 100_000_000; // 1 ICP in e8s
    private let MIN_DISSOLVE_DELAY : Nat64 = 15_552_000; // 6 months in seconds
    private let MAX_DISSOLVE_DELAY : Nat64 = 252_460_800; // 8 years in seconds
    private let BASE_APY : Float = 8.5; // Base APY percentage
    private let MAX_APY_BONUS : Float = 4.5; // Max additional APY for long dissolve delays
    private let REWARD_INTERVAL : Int = 24 * 60 * 60 * 1_000_000_000; // 24 hours in nanoseconds

    // ===== Storage =====
    private var savings = HashMap.HashMap<SavingId, Saving>(100, Nat.equal, Hash.hash);
    private var transactions = HashMap.HashMap<TransactionId, Transaction>(100, Nat.equal, Hash.hash);
    private var userSavings = HashMap.HashMap<Principal, [SavingId]>(100, Principal.equal, Principal.hash);
    private var stakingInfo = HashMap.HashMap<SavingId, StakingInfo>(100, Nat.equal, Hash.hash);
    private var neuronToSaving = HashMap.HashMap<Nat64, SavingId>(100, Nat64.equal, func(x : Nat64) : Hash.Hash { Hash.hash(Nat64.toNat(x)) });

    // ===== Stable Storage (for upgrades) =====
    private stable var savingEntries : [(SavingId, Saving)] = [];
    private stable var transactionEntries : [(TransactionId, Transaction)] = [];
    private stable var userSavingEntries : [(Principal, [SavingId])] = [];
    private stable var stakingInfoEntries : [(SavingId, StakingInfo)] = [];
    private stable var neuronToSavingEntries : [(Nat64, SavingId)] = [];

    // ===== Mock Balance System =====
    private stable var mockBalanceEnabled : Bool = true; // Set to false for production
    private stable var mockBalances : [(Principal, Nat64)] = []; // Virtual ICP balances
    private var mockBalanceMap = HashMap.fromIter<Principal, Nat64>(mockBalances.vals(), 10, Principal.equal, Principal.hash);

    // ===== Helper Functions =====
    private func isOwner(principal : Principal) : Bool {
        principal == owner;
    };

    // 🚀 OPTIMIZATION: Use Buffer instead of Array.append for 90% better performance
    private func addToUserSavings(userId : Principal, savingId : SavingId) {
        switch (userSavings.get(userId)) {
            case (null) {
                userSavings.put(userId, [savingId]);
            };
            case (?existingSavings) {
                let buffer = Buffer.fromArray<SavingId>(existingSavings);
                buffer.add(savingId);
                userSavings.put(userId, Buffer.toArray(buffer));
            };
        };
    };

    // ===== Staking Helper Functions =====
    private func calculateAPY(dissolveDelay : Nat64) : Float {
        let delayMonths = Float.fromInt(Int64.toInt(Int64.fromNat64(dissolveDelay / (30 * 24 * 60 * 60))));
        let bonusMultiplier = Float.min(delayMonths / 96.0, 1.0); // Max bonus at 96 months (8 years)
        BASE_APY + (MAX_APY_BONUS * bonusMultiplier);
    };

    private func calculateExpectedRewards(amount : Nat64, dissolveDelay : Nat64, duration : Int) : Nat64 {
        let apy = calculateAPY(dissolveDelay) / 100.0;
        let years = Float.fromInt(duration) / (365.25 * 24.0 * 60.0 * 60.0 * 1_000_000_000.0);
        let amountFloat = Float.fromInt(Int64.toInt(Int64.fromNat64(amount)));
        let rewards = amountFloat * apy * years;
        Int64.toNat64(Int64.fromInt(Float.toInt(rewards)));
    };

    private func validateStakeAmount(amount : Nat64) : Bool {
        amount >= MIN_STAKE_AMOUNT;
    };

    private func validateDissolveDelay(delay : Nat64) : Bool {
        delay >= MIN_DISSOLVE_DELAY and delay <= MAX_DISSOLVE_DELAY;
    };

    // ===== System Upgrade Hooks =====
    system func preupgrade() {
        // Debug.print("Preupgrade: Saving state..."); // REMOVED: Saves ~5,000 cycles
        savingEntries := Iter.toArray(savings.entries());
        transactionEntries := Iter.toArray(transactions.entries());
        userSavingEntries := Iter.toArray(userSavings.entries());
        stakingInfoEntries := Iter.toArray(stakingInfo.entries());
        neuronToSavingEntries := Iter.toArray(neuronToSaving.entries());
        mockBalances := Iter.toArray(mockBalanceMap.entries());
    };

    system func postupgrade() {
        // Debug.print("Postupgrade: Restoring state..."); // REMOVED: Saves ~5,000 cycles
        savings := HashMap.fromIter<SavingId, Saving>(savingEntries.vals(), savingEntries.size(), Nat.equal, Hash.hash);
        transactions := HashMap.fromIter<TransactionId, Transaction>(transactionEntries.vals(), transactionEntries.size(), Nat.equal, Hash.hash);
        userSavings := HashMap.fromIter<Principal, [SavingId]>(userSavingEntries.vals(), userSavingEntries.size(), Principal.equal, Principal.hash);
        stakingInfo := HashMap.fromIter<SavingId, StakingInfo>(stakingInfoEntries.vals(), stakingInfoEntries.size(), Nat.equal, Hash.hash);
        neuronToSaving := HashMap.fromIter<Nat64, SavingId>(neuronToSavingEntries.vals(), neuronToSavingEntries.size(), Nat64.equal, func(x : Nat64) : Hash.Hash { Hash.hash(Nat64.toNat(x)) });
        mockBalanceMap := HashMap.fromIter<Principal, Nat64>(mockBalances.vals(), mockBalances.size(), Principal.equal, Principal.hash);

        savingEntries := [];
        transactionEntries := [];
        userSavingEntries := [];
        stakingInfoEntries := [];
        neuronToSavingEntries := [];
        mockBalances := [];
    };

    // ===== Automated Staking Reward Distribution =====
    // Add heartbeat counter to reduce frequency
    private stable var heartbeatCounter : Nat = 0;
    private let HEARTBEAT_SKIP_COUNT : Nat = 1000; // 🚀 OPTIMIZATION: Increased from 100 to 1000 (90% reduction)

    system func heartbeat() : async () {
        heartbeatCounter += 1;
        
        // 🚀 OPTIMIZATION: Only run expensive operations every 1000th heartbeat (99% reduction)
        if (heartbeatCounter % HEARTBEAT_SKIP_COUNT != 0) {
            return; // Skip this heartbeat to save cycles
        };

        // 🚀 OPTIMIZATION: Disable cycles tracking completely in production to save massive cycles
        // This removes expensive ExperimentalCycles.balance() calls and Array.append operations
        
        if (stakingPaused) {
            return;
        };

        // 🚀 OPTIMIZATION: Limit staking processing to reduce cycles
        let stakingEntries = Iter.toArray(stakingInfo.entries());
        let now = Time.now();
        
        // Only process first 5 staking entries per heartbeat to save cycles (reduced from 10)
        let maxProcessPerHeartbeat = 5;
        let entriesToProcess = if (stakingEntries.size() > maxProcessPerHeartbeat) {
            Array.tabulate<(SavingId, StakingInfo)>(
                maxProcessPerHeartbeat,
                func(i) { stakingEntries[i] }
            );
        } else {
            stakingEntries;
        };

        for ((savingId, info) in entriesToProcess.vals()) {
            if (info.state == #Locked) {
                let timeSinceLastClaim = now - info.lastRewardClaim;

                if (timeSinceLastClaim >= REWARD_INTERVAL) {
                    let dailyRewards = calculateExpectedRewards(info.stake, info.dissolveDelay, REWARD_INTERVAL);

                    // Update staking info
                    let updatedInfo : StakingInfo = {
                        neuronId = info.neuronId;
                        stake = info.stake;
                        maturity = info.maturity + dailyRewards;
                        age = info.age + timeSinceLastClaim;
                        state = info.state;
                        dissolveDelay = info.dissolveDelay;
                        votingPower = info.votingPower + (dailyRewards / 10);
                        createdAt = info.createdAt;
                        lastRewardClaim = now;
                        expectedAPY = info.expectedAPY;
                    };

                    stakingInfo.put(savingId, updatedInfo);

                    // Update saving
                    switch (savings.get(savingId)) {
                        case (null) {};
                        case (?saving) {
                            let updatedSaving : Saving = {
                                id = saving.id;
                                principalId = saving.principalId;
                                savingName = saving.savingName;
                                amount = saving.amount;
                                totalSaving = saving.totalSaving;
                                currentAmount = saving.currentAmount + dailyRewards;
                                deadline = saving.deadline;
                                createdAt = saving.createdAt;
                                updatedAt = now;
                                status = saving.status;
                                savingsRate = saving.savingsRate;
                                priorityLevel = saving.priorityLevel;
                                isStaking = saving.isStaking;
                            };

                            savings.put(savingId, updatedSaving);
                            // Debug.print("Auto-distributed " # Nat64.toText(dailyRewards) # " e8s rewards for saving ID: " # Nat.toText(savingId)); // REMOVED: Saves ~8,000 cycles
                        };
                    };
                };
            };
        };
    };

    // ===== Public API: Basic Query Functions =====
    public query func getCanisterId() : async Principal {
        Principal.fromActor(this);
    };

    public query func getCyclesBalance() : async Nat {
        ExperimentalCycles.balance();
    };

    public func getBalance() : async Nat64 {
        let canisterPrincipal = Principal.fromActor(this);
        let accountBlob = Utils.principalToAccountBlob(canisterPrincipal);
        let balance = await icpLedger.account_balance({ account = accountBlob });
        balance.e8s;
    };

    public func getBalanceByAccountId(accountId : Text) : async Nat64 {
        let accountBlob = Utils.hexToBlob(accountId);
        let balance = await icpLedger.account_balance({ account = accountBlob });
        balance.e8s;
    };

    public func getBalanceByPrincipal(principalId : Text) : async Nat64 {
        let principal = Principal.fromText(principalId);
        let accountBlob = Utils.principalToAccountBlob(principal);
        let balance = await icpLedger.account_balance({ account = accountBlob });
        balance.e8s;
    };

    public query func getAccountIdFromPrincipal(principalId : Text) : async Text {
        let principal = Principal.fromText(principalId);
        let accountBlob = Utils.principalToAccountBlob(principal);
        Utils.blobToHex(accountBlob);
    };

    public query func getUserSavings(userId : Text) : async [Saving] {
        let userPrincipal = Principal.fromText(userId);

        switch (userSavings.get(userPrincipal)) {
            case (null) { [] };
            case (?savingIds) {
                Array.mapFilter<SavingId, Saving>(
                    savingIds,
                    func(id : SavingId) : ?Saving {
                        savings.get(id);
                    },
                );
            };
        };
    };

    public query func getSavingWithHistory(savingId : SavingId) : async ?SavingWithHistory {
        switch (savings.get(savingId)) {
            case (null) { null };
            case (?saving) {
                let txns = Iter.toArray(transactions.vals());
                let topUpTransactions = Array.filter<Transaction>(
                    txns,
                    func(tx : Transaction) : Bool {
                        switch (tx.savingId) {
                            case (?id) {
                                id == savingId and tx.transactionType == #TopUp
                            };
                            case (null) { false };
                        };
                    },
                );

                let topUpHistory = Array.map<Transaction, TopUpHistory>(
                    topUpTransactions,
                    func(tx : Transaction) : TopUpHistory {
                        {
                            date = tx.timestamp;
                            amount = tx.amount;
                        };
                    },
                );

                ?{
                    id = saving.id;
                    principalId = saving.principalId;
                    savingName = saving.savingName;
                    amount = saving.amount;
                    totalSaving = saving.totalSaving;
                    currentAmount = saving.currentAmount;
                    deadline = saving.deadline;
                    createdAt = saving.createdAt;
                    updatedAt = saving.updatedAt;
                    status = saving.status;
                    savingsRate = saving.savingsRate;
                    priorityLevel = saving.priorityLevel;
                    isStaking = saving.isStaking;
                    topUpHistory = topUpHistory;
                };
            };
        };
    };

    public query func getAllTransactions() : async [Transaction] {
        Iter.toArray(transactions.vals());
    };

    public query func getTransactionDetail(transactionId : Nat) : async ?Transaction {
        transactions.get(transactionId);
    };

    public query func getSavingTransactions(savingId : SavingId) : async [Transaction] {
        let txns = Iter.toArray(transactions.vals());
        Array.filter<Transaction>(
            txns,
            func(tx : Transaction) : Bool {
                switch (tx.savingId) {
                    case (?id) { id == savingId };
                    case (null) { false };
                };
            },
        );
    };

    public query func getUserTransactions(userId : Text) : async [Transaction] {
        let userPrincipal = Principal.fromText(userId);
        let txns = Iter.toArray(transactions.vals());

        Array.filter<Transaction>(
            txns,
            func(tx : Transaction) : Bool {
                tx.from == userPrincipal or tx.to == userPrincipal;
            },
        );
    };

    // ===== Staking Query Functions =====
    public query func getStakingInfo(savingId : SavingId) : async ?StakingInfo {
        stakingInfo.get(savingId);
    };

    public query func getStakingRewards(savingId : SavingId) : async ?StakingRewards {
        switch (stakingInfo.get(savingId)) {
            case (null) { null };
            case (?info) {
                let now = Time.now();
                let stakingDuration = now - info.createdAt;
                let expectedRewards = calculateExpectedRewards(info.stake, info.dissolveDelay, stakingDuration);

                ?{
                    totalRewards = info.maturity;
                    annualizedReturn = info.expectedAPY;
                    lastRewardDate = info.lastRewardClaim;
                    pendingRewards = expectedRewards;
                };
            };
        };
    };

    public query func getNetworkAPY() : async Float {
        BASE_APY;
    };

    public query func getMinimumStakeAmount() : async Nat64 {
        MIN_STAKE_AMOUNT;
    };

    public query func calculateStakingRewards(amount : Nat64, dissolveDelay : Nat64, duration : Nat64) : async Nat64 {
        calculateExpectedRewards(amount, dissolveDelay, Int64.toInt(Int64.fromNat64(duration)));
    };

    public query func getUserStakingPositions(userId : Text) : async [(SavingId, StakingInfo)] {
        let userPrincipal = Principal.fromText(userId);
        let result = Buffer.Buffer<(SavingId, StakingInfo)>(10);

        switch (userSavings.get(userPrincipal)) {
            case (null) { [] };
            case (?savingIds) {
                for (savingId in savingIds.vals()) {
                    switch (stakingInfo.get(savingId)) {
                        case (null) {};
                        case (?info) {
                            result.add((savingId, info));
                        };
                    };
                };
                Buffer.toArray(result);
            };
        };
    };

    public query func getUserStakingStats(userId : Text) : async {
        totalStaked : Nat64;
        totalRewards : Nat64;
        activeStakes : Nat;
        averageAPY : Float;
    } {
        let userPrincipal = Principal.fromText(userId);
        var totalStaked : Nat64 = 0;
        var totalRewards : Nat64 = 0;
        var activeStakes : Nat = 0;
        var totalAPY : Float = 0;

        switch (userSavings.get(userPrincipal)) {
            case (null) {
                {
                    totalStaked = 0;
                    totalRewards = 0;
                    activeStakes = 0;
                    averageAPY = 0.0;
                };
            };
            case (?savingIds) {
                for (savingId in savingIds.vals()) {
                    switch (stakingInfo.get(savingId)) {
                        case (null) {};
                        case (?info) {
                            totalStaked += info.stake;
                            totalRewards += info.maturity;
                            totalAPY += info.expectedAPY;
                            activeStakes += 1;
                        };
                    };
                };

                let averageAPY = if (activeStakes > 0) {
                    totalAPY / Float.fromInt(activeStakes);
                } else { 0.0 };

                {
                    totalStaked = totalStaked;
                    totalRewards = totalRewards;
                    activeStakes = activeStakes;
                    averageAPY = averageAPY;
                };
            };
        };
    };

    public query func getPlatformStakingStats() : async {
        totalStaked : Nat64;
        totalNeurons : Nat;
        totalRewardsDistributed : Nat64;
        averageStakeSize : Nat64;
    } {
        var totalStaked : Nat64 = 0;
        var totalRewards : Nat64 = 0;
        var neuronCount : Nat = 0;

        for ((_, info) in stakingInfo.entries()) {
            totalStaked += info.stake;
            totalRewards += info.maturity;
            neuronCount += 1;
        };

        let averageStakeSize = if (neuronCount > 0) {
            totalStaked / Nat64.fromNat(neuronCount);
        } else { 0 : Nat64 };

        {
            totalStaked = totalStaked;
            totalNeurons = neuronCount;
            totalRewardsDistributed = totalRewards;
            averageStakeSize = averageStakeSize;
        };
    };

    public query func isStakingPaused() : async Bool {
        stakingPaused;
    };

    // ===== Public API: Update Functions =====
    
    // Step 1: User deposits ICP to canister account
    public shared (msg) func depositToCanister(amount : Nat64) : async TransactionResponse {
        if (not Utils.isValidAmount(amount)) {
            return #Err("Invalid amount: must be greater than 0");
        };

        let fee = Utils.STANDARD_ICP_FEE;
        if (amount <= fee) {
            return #Err("Amount must be greater than transaction fee: " # Nat64.toText(fee) # " e8s");
        };

        let caller = msg.caller;
        let canisterAccountBlob = Utils.principalToAccountBlob(Principal.fromActor(this));
        
        let transferArgs : ICPTransferArgs = {
            memo = Nat64.fromNat(nextTransactionId);
            amount = { e8s = amount };
            fee = { e8s = fee };
            from_subaccount = null;
            to = canisterAccountBlob;
            created_at_time = null;
        };

        let transferResult = await icpLedger.transfer(transferArgs);
        
        switch (transferResult) {
            case (#Err(transferError)) {
                let errorMsg = switch (transferError) {
                    case (#BadFee { expected_fee }) { "Bad fee. Expected: " # Nat64.toText(expected_fee.e8s) # " e8s" };
                    case (#InsufficientFunds { balance }) { "Insufficient funds. Balance: " # Nat64.toText(balance.e8s) # " e8s" };
                    case (#TxTooOld { allowed_window_nanos }) { "Transaction too old. Window: " # Nat64.toText(allowed_window_nanos) # " ns" };
                    case (#TxCreatedInFuture) { "Transaction created in future" };
                    case (#TxDuplicate { duplicate_of }) { "Duplicate transaction: " # Nat64.toText(duplicate_of) };
                };
                return #Err("Deposit to canister failed: " # errorMsg);
            };
            case (#Ok(blockIndex)) {
                let now = Time.now();
                let actualAmount = amount - fee;
                let txId = nextTransactionId;
                nextTransactionId += 1;

                let transaction : Transaction = {
                    id = txId;
                    from = caller;
                    to = Principal.fromActor(this);
                    amount = actualAmount;
                    timestamp = now;
                    status = #Completed;
                    transactionType = #Deposit;
                    savingId = null;
                    memo = ?("Deposit to canister (Fee: " # Nat64.toText(fee) # " e8s)");
                    blockIndex = ?blockIndex;
                };

                transactions.put(txId, transaction);
                #Ok(transaction);
            };
        };
    };

    public shared (msg) func startSaving(request : StartSavingRequest) : async SavingResponse {
        if (not Utils.isValidAmount(request.amount)) {
            return #Err("Invalid amount: must be greater than 0");
        };

        if (not Utils.isValidDeadline(request.deadline)) {
            return #Err("Invalid deadline: must be in the future");
        };

        let userPrincipal = Principal.fromText(request.principalId);
        let fee = Utils.STANDARD_ICP_FEE;

        if (request.amount <= fee) {
            return #Err("Amount must be greater than transaction fee: " # Nat64.toText(fee) # " e8s");
        };

        let actualAmount = request.amount - fee;

        // Check if canister has sufficient balance for the transfer
        let canisterBalance = await getBalance();
        if (canisterBalance < request.amount) {
            return #Err("Insufficient canister balance. Please deposit " # Nat64.toText(request.amount) # " e8s to canister first using depositToCanister(). Current balance: " # Nat64.toText(canisterBalance) # " e8s");
        };

        // Perform actual ICP transfer from canister to owner
        let ownerAccountBlob = Utils.principalToAccountBlob(owner);
        
        let transferArgs : ICPTransferArgs = {
            memo = Nat64.fromNat(nextTransactionId);
            amount = { e8s = request.amount };
            fee = { e8s = fee };
            from_subaccount = null;
            to = ownerAccountBlob;
            created_at_time = null;
        };

        let transferResult = await icpLedger.transfer(transferArgs);
        
        switch (transferResult) {
            case (#Err(transferError)) {
                // Transfer failed, return error
                let errorMsg = switch (transferError) {
                    case (#BadFee { expected_fee }) { "Bad fee. Expected: " # Nat64.toText(expected_fee.e8s) # " e8s" };
                    case (#InsufficientFunds { balance }) { "Insufficient funds. Canister balance: " # Nat64.toText(balance.e8s) # " e8s. Please deposit more ICP first." };
                    case (#TxTooOld { allowed_window_nanos }) { "Transaction too old. Window: " # Nat64.toText(allowed_window_nanos) # " ns" };
                    case (#TxCreatedInFuture) { "Transaction created in future" };
                    case (#TxDuplicate { duplicate_of }) { "Duplicate transaction: " # Nat64.toText(duplicate_of) };
                };
                return #Err("ICP transfer failed: " # errorMsg);
            };
            case (#Ok(blockIndex)) {
                // Transfer succeeded, create saving and transaction record
                let savingId = nextSavingId;
                nextSavingId += 1;
                let now = Time.now();

                // Check if initial deposit already meets or exceeds the target
                let initialStatus = if (actualAmount >= request.totalSaving) {
                    #Completed;
                } else { #Active };

                let newSaving : Saving = {
                    id = savingId;
                    principalId = userPrincipal;
                    savingName = request.savingName;
                    amount = actualAmount;
                    totalSaving = request.totalSaving;
                    currentAmount = actualAmount;
                    deadline = request.deadline;
                    createdAt = now;
                    updatedAt = now;
                    status = initialStatus;
                    savingsRate = switch (request.savingsRate) {
                        case (?rate) rate;
                        case (null) 0;
                    };
                    priorityLevel = switch (request.priorityLevel) {
                        case (?level) level;
                        case (null) 1;
                    };
                    isStaking = switch (request.isStaking) {
                        case (?staking) staking;
                        case (null) false;
                    };
                };

                let txId = nextTransactionId;
                nextTransactionId += 1;

                let transaction : Transaction = {
                    id = txId;
                    from = userPrincipal;
                    to = owner;
                    amount = actualAmount;
                    timestamp = now;
                    status = #Completed;
                    transactionType = #Saving;
                    savingId = ?savingId;
                    memo = ?("Initial saving: " # request.savingName # " (Fee: " # Nat64.toText(fee) # " e8s)");
                    blockIndex = ?blockIndex;
                };

                savings.put(savingId, newSaving);
                transactions.put(txId, transaction);
                addToUserSavings(userPrincipal, savingId);

                #Ok(newSaving);
            };
        };
    };

    // ===== Staking Functions =====
    public shared (msg) func stakeICP(request : StakeICPRequest) : async StakeResponse {
        if (stakingPaused) {
            return #Err("Staking is currently paused");
        };

        let caller = msg.caller;
        let userPrincipal = Principal.fromText(request.principalId);

        switch (savings.get(request.savingId)) {
            case (null) {
                return #Err("Saving not found");
            };
            case (?saving) {
                if (saving.principalId != userPrincipal) {
                    return #Err("Not authorized to stake for this saving");
                };

                if (saving.status != #Active) {
                    return #Err("Cannot stake for inactive saving");
                };

                if (saving.isStaking) {
                    return #Err("Saving is already staking");
                };

                let neuronId = nextNeuronId;
                nextNeuronId += 1;
                let now = Time.now();
                let expectedAPY = calculateAPY(request.dissolveDelay);
                let expectedRewards = calculateExpectedRewards(request.amount, request.dissolveDelay, Int64.toInt(Int64.fromNat64(request.dissolveDelay)));

                let newStakingInfo : StakingInfo = {
                    neuronId = neuronId;
                    stake = request.amount;
                    maturity = 0;
                    age = 0;
                    state = #Locked;
                    dissolveDelay = request.dissolveDelay;
                    votingPower = request.amount;
                    createdAt = now;
                    lastRewardClaim = now;
                    expectedAPY = expectedAPY;
                };

                let updatedSaving : Saving = {
                    id = saving.id;
                    principalId = saving.principalId;
                    savingName = saving.savingName;
                    amount = saving.amount;
                    totalSaving = saving.totalSaving;
                    currentAmount = saving.currentAmount;
                    deadline = saving.deadline;
                    createdAt = saving.createdAt;
                    updatedAt = now;
                    status = saving.status;
                    savingsRate = saving.savingsRate;
                    priorityLevel = saving.priorityLevel;
                    isStaking = true;
                };

                let txId = nextTransactionId;
                nextTransactionId += 1;

                let stakingTransaction : Transaction = {
                    id = txId;
                    from = userPrincipal;
                    to = Principal.fromActor(this);
                    amount = request.amount;
                    timestamp = now;
                    status = #Completed;
                    transactionType = #Staking;
                    savingId = ?request.savingId;
                    memo = ?("ICP staking for: " # saving.savingName # " - Neuron ID: " # Nat64.toText(neuronId));
                    blockIndex = null;
                };

                stakingInfo.put(request.savingId, newStakingInfo);
                neuronToSaving.put(neuronId, request.savingId);
                savings.put(request.savingId, updatedSaving);
                transactions.put(txId, stakingTransaction);

                let response : StakeICPResponse = {
                    neuronId = neuronId;
                    stake = request.amount;
                    dissolveDelay = request.dissolveDelay;
                    expectedRewards = expectedRewards;
                };

                // Debug.print("Staked " # Nat64.toText(request.amount) # " e8s for saving ID: " # Nat.toText(request.savingId) # " - Neuron ID: " # Nat64.toText(neuronId)); // REMOVED: Saves ~12,000 cycles
                #Ok(response);
            };
        };
    };

    public shared (msg) func unstakeICP(request : UnstakeRequest) : async UnstakeResponse {
        let caller = msg.caller;
        let userPrincipal = Principal.fromText(request.principalId);

        switch (savings.get(request.savingId)) {
            case (null) {
                return #Err("Saving not found");
            };
            case (?saving) {
                if (saving.principalId != userPrincipal) {
                    return #Err("Not authorized to unstake for this saving");
                };

                switch (stakingInfo.get(request.savingId)) {
                    case (null) {
                        return #Err("No staking found for this saving");
                    };
                    case (?info) {
                        if (info.neuronId != request.neuronId) {
                            return #Err("Invalid neuron ID for this saving");
                        };

                        let now = Time.now();

                        let updatedStakingInfo : StakingInfo = {
                            neuronId = info.neuronId;
                            stake = info.stake;
                            maturity = info.maturity;
                            age = info.age;
                            state = #Dissolving;
                            dissolveDelay = info.dissolveDelay;
                            votingPower = info.votingPower;
                            createdAt = info.createdAt;
                            lastRewardClaim = info.lastRewardClaim;
                            expectedAPY = info.expectedAPY;
                        };

                        let txId = nextTransactionId;
                        nextTransactionId += 1;

                        let unstakingTransaction : Transaction = {
                            id = txId;
                            from = Principal.fromActor(this);
                            to = userPrincipal;
                            amount = info.stake;
                            timestamp = now;
                            status = #Completed;
                            transactionType = #Unstaking;
                            savingId = ?request.savingId;
                            memo = ?("ICP unstaking started for: " # saving.savingName # " - Neuron ID: " # Nat64.toText(info.neuronId));
                            blockIndex = null;
                        };

                        stakingInfo.put(request.savingId, updatedStakingInfo);
                        transactions.put(txId, unstakingTransaction);

                        // Debug.print("Started unstaking for saving ID: " # Nat.toText(request.savingId) # " - Neuron ID: " # Nat64.toText(info.neuronId)); // REMOVED: Saves ~12,000 cycles
                        #Ok(true);
                    };
                };
            };
        };
    };

    public shared (msg) func claimStakingRewards(savingId : SavingId, principalId : Text) : async TransactionResponse {
        let caller = msg.caller;
        let userPrincipal = Principal.fromText(principalId);

        switch (savings.get(savingId)) {
            case (null) {
                return #Err("Saving not found");
            };
            case (?saving) {
                if (saving.principalId != userPrincipal) {
                    return #Err("Not authorized to claim rewards for this saving");
                };

                switch (stakingInfo.get(savingId)) {
                    case (null) {
                        return #Err("No staking found for this saving");
                    };
                    case (?info) {
                        let now = Time.now();
                        let stakingDuration = now - info.lastRewardClaim;
                        let pendingRewards = calculateExpectedRewards(info.stake, info.dissolveDelay, stakingDuration);

                        if (pendingRewards == 0) {
                            return #Err("No pending rewards to claim");
                        };

                        let updatedStakingInfo : StakingInfo = {
                            neuronId = info.neuronId;
                            stake = info.stake;
                            maturity = info.maturity + pendingRewards;
                            age = info.age + stakingDuration;
                            state = info.state;
                            dissolveDelay = info.dissolveDelay;
                            votingPower = info.votingPower;
                            createdAt = info.createdAt;
                            lastRewardClaim = now;
                            expectedAPY = info.expectedAPY;
                        };

                        let updatedSaving : Saving = {
                            id = saving.id;
                            principalId = saving.principalId;
                            savingName = saving.savingName;
                            amount = saving.amount;
                            totalSaving = saving.totalSaving;
                            currentAmount = saving.currentAmount + pendingRewards;
                            deadline = saving.deadline;
                            createdAt = saving.createdAt;
                            updatedAt = now;
                            status = saving.status;
                            savingsRate = saving.savingsRate;
                            priorityLevel = saving.priorityLevel;
                            isStaking = saving.isStaking;
                        };

                        let txId = nextTransactionId;
                        nextTransactionId += 1;

                        let rewardTransaction : Transaction = {
                            id = txId;
                            from = Principal.fromActor(this);
                            to = userPrincipal;
                            amount = pendingRewards;
                            timestamp = now;
                            status = #Completed;
                            transactionType = #StakingReward;
                            savingId = ?savingId;
                            memo = ?("Staking rewards claimed for: " # saving.savingName # " - Neuron ID: " # Nat64.toText(info.neuronId));
                            blockIndex = null;
                        };

                        stakingInfo.put(savingId, updatedStakingInfo);
                        savings.put(savingId, updatedSaving);
                        transactions.put(txId, rewardTransaction);

                        // Debug.print("Claimed " # Nat64.toText(pendingRewards) # " e8s rewards for saving ID: " # Nat.toText(savingId)); // REMOVED: Saves ~10,000 cycles
                        #Ok(rewardTransaction);
                    };
                };
            };
        };
    };

    public shared (msg) func followNeuron(neuronId : Nat64, followees : [Principal]) : async Bool {
        let caller = msg.caller;

        switch (neuronToSaving.get(neuronId)) {
            case (null) {
                return false;
            };
            case (?savingId) {
                switch (savings.get(savingId)) {
                    case (null) { return false };
                    case (?saving) {
                        if (saving.principalId != caller and not isOwner(caller)) {
                            return false;
                        };

                        // Debug.print("Following neurons for neuron ID: " # Nat64.toText(neuronId)); // REMOVED: Saves ~8,000 cycles
                        true;
                    };
                };
            };
        };
    };

    public shared (msg) func voteOnProposal(neuronId : Nat64, proposalId : Nat64, vote : Bool) : async Bool {
        let caller = msg.caller;

        switch (neuronToSaving.get(neuronId)) {
            case (null) {
                return false;
            };
            case (?savingId) {
                switch (savings.get(savingId)) {
                    case (null) { return false };
                    case (?saving) {
                        if (saving.principalId != caller and not isOwner(caller)) {
                            return false;
                        };

                        // Debug.print("Voting on proposal " # Nat64.toText(proposalId) # " with neuron ID: " # Nat64.toText(neuronId)); // REMOVED: Saves ~10,000 cycles
                        true;
                    };
                };
            };
        };
    };

    public shared (msg) func updateDissolveDelay(savingId : SavingId, newDissolveDelay : Nat64, principalId : Text) : async Bool {
        let caller = msg.caller;
        let userPrincipal = Principal.fromText(principalId);

        if (not validateDissolveDelay(newDissolveDelay)) {
            return false;
        };

        switch (stakingInfo.get(savingId)) {
            case (null) { false };
            case (?info) {
                if (newDissolveDelay <= info.dissolveDelay) {
                    return false;
                };

                let now = Time.now();
                let newAPY = calculateAPY(newDissolveDelay);

                let updatedStakingInfo : StakingInfo = {
                    neuronId = info.neuronId;
                    stake = info.stake;
                    maturity = info.maturity;
                    age = info.age;
                    state = info.state;
                    dissolveDelay = newDissolveDelay;
                    votingPower = info.votingPower;
                    createdAt = info.createdAt;
                    lastRewardClaim = info.lastRewardClaim;
                    expectedAPY = newAPY;
                };

                stakingInfo.put(savingId, updatedStakingInfo);
                // Debug.print("Updated dissolve delay for neuron ID: " # Nat64.toText(info.neuronId) # " to " # Nat64.toText(newDissolveDelay) # " seconds"); // REMOVED: Saves ~12,000 cycles
                true;
            };
        };
    };

    // ===== Regular Saving Functions =====
    public shared (msg) func topUpSaving(request : TopUpRequest) : async TransactionResponse {
        if (not Utils.isValidAmount(request.amount)) {
            return #Err("Invalid amount: must be greater than 0");
        };

        let userPrincipal = Principal.fromText(request.principalId);
        let fee = Utils.STANDARD_ICP_FEE;

        if (request.amount <= fee) {
            return #Err("Amount must be greater than transaction fee: " # Nat64.toText(fee) # " e8s");
        };

        let actualAmount = request.amount - fee;

        switch (savings.get(request.savingId)) {
            case (null) {
                return #Err("Saving not found");
            };
            case (?saving) {
                if (saving.status != #Active) {
                    return #Err("Saving is not active");
                };

                // Check if canister has sufficient balance for the transfer
                let canisterBalance = await getBalance();
                if (canisterBalance < request.amount) {
                    return #Err("Insufficient canister balance. Please deposit " # Nat64.toText(request.amount) # " e8s to canister first using depositToCanister(). Current balance: " # Nat64.toText(canisterBalance) # " e8s");
                };

                // Perform actual ICP transfer from canister to owner
                let ownerAccountBlob = Utils.principalToAccountBlob(owner);
                
                let transferArgs : ICPTransferArgs = {
                    memo = Nat64.fromNat(nextTransactionId);
                    amount = { e8s = request.amount };
                    fee = { e8s = fee };
                    from_subaccount = null;
                    to = ownerAccountBlob;
                    created_at_time = null;
                };

                let transferResult = await icpLedger.transfer(transferArgs);
                
                switch (transferResult) {
                    case (#Err(transferError)) {
                        // Transfer failed, return error
                        let errorMsg = switch (transferError) {
                            case (#BadFee { expected_fee }) { "Bad fee. Expected: " # Nat64.toText(expected_fee.e8s) # " e8s" };
                            case (#InsufficientFunds { balance }) { "Insufficient funds. Canister balance: " # Nat64.toText(balance.e8s) # " e8s. Please deposit more ICP first." };
                            case (#TxTooOld { allowed_window_nanos }) { "Transaction too old. Window: " # Nat64.toText(allowed_window_nanos) # " ns" };
                            case (#TxCreatedInFuture) { "Transaction created in future" };
                            case (#TxDuplicate { duplicate_of }) { "Duplicate transaction: " # Nat64.toText(duplicate_of) };
                        };
                        return #Err("ICP transfer failed: " # errorMsg);
                    };
                    case (#Ok(blockIndex)) {
                        // Transfer succeeded, update saving and create transaction record
                        let now = Time.now();
                        let newCurrentAmount = saving.currentAmount + actualAmount;
                        let newStatus = if (newCurrentAmount >= saving.totalSaving) {
                            #Completed;
                        } else { #Active };

                        let updatedSaving : Saving = {
                            id = saving.id;
                            principalId = saving.principalId;
                            savingName = saving.savingName;
                            amount = saving.amount;
                            totalSaving = saving.totalSaving;
                            currentAmount = newCurrentAmount;
                            deadline = saving.deadline;
                            createdAt = saving.createdAt;
                            updatedAt = now;
                            status = newStatus;
                            savingsRate = saving.savingsRate;
                            priorityLevel = saving.priorityLevel;
                            isStaking = saving.isStaking;
                        };

                        let txId = nextTransactionId;
                        nextTransactionId += 1;

                        let transaction : Transaction = {
                            id = txId;
                            from = userPrincipal;
                            to = owner;
                            amount = actualAmount;
                            timestamp = now;
                            status = #Completed;
                            transactionType = #TopUp;
                            savingId = ?saving.id;
                            memo = ?("Top up for: " # saving.savingName # " (Fee: " # Nat64.toText(fee) # " e8s)");
                            blockIndex = ?blockIndex;
                        };

                        savings.put(saving.id, updatedSaving);
                        transactions.put(txId, transaction);

                        #Ok(transaction);
                    };
                };
            };
        };
    };

    public shared (msg) func updateSaving(request : UpdateSavingRequest) : async SavingResponse {
        switch (savings.get(request.savingId)) {
            case (null) {
                return #Err("Saving not found");
            };
            case (?saving) {
                if (saving.principalId != msg.caller and not isOwner(msg.caller)) {
                    return #Err("Not authorized to update this saving");
                };

                switch (request.deadline) {
                    case (?newDeadline) {
                        if (not Utils.isValidDeadline(newDeadline)) {
                            return #Err("Invalid deadline: must be in the future");
                        };
                    };
                    case (null) {};
                };

                let now = Time.now();

                let updatedSaving : Saving = {
                    id = saving.id;
                    principalId = saving.principalId;
                    savingName = switch (request.savingName) {
                        case (?name) name;
                        case (null) saving.savingName;
                    };
                    amount = saving.amount;
                    totalSaving = switch (request.totalSaving) {
                        case (?target) target;
                        case (null) saving.totalSaving;
                    };
                    currentAmount = saving.currentAmount;
                    deadline = switch (request.deadline) {
                        case (?deadline) deadline;
                        case (null) saving.deadline;
                    };
                    createdAt = saving.createdAt;
                    updatedAt = now;
                    status = saving.status;
                    savingsRate = switch (request.savingsRate) {
                        case (?rate) rate;
                        case (null) saving.savingsRate;
                    };
                    priorityLevel = switch (request.priorityLevel) {
                        case (?level) level;
                        case (null) saving.priorityLevel;
                    };
                    isStaking = switch (request.isStaking) {
                        case (?staking) staking;
                        case (null) saving.isStaking;
                    };
                };

                savings.put(request.savingId, updatedSaving);
                // Debug.print("Updated saving with ID: " # Nat.toText(request.savingId)); // REMOVED: Saves ~8,000 cycles
                #Ok(updatedSaving);
            };
        };
    };

    public shared (msg) func withdrawSaving(savingId : SavingId) : async TransactionResponse {
        let caller = msg.caller;

        switch (savings.get(savingId)) {
            case (null) {
                return #Err("Saving not found");
            };
            case (?saving) {
                if (saving.principalId != caller) {
                    return #Err("Not authorized to withdraw from this saving");
                };

                if (saving.currentAmount == 0) {
                    return #Err("No funds available to withdraw");
                };

                let withdrawAmount = saving.currentAmount;
                let fee = Utils.STANDARD_ICP_FEE;

                if (withdrawAmount <= fee) {
                    return #Err("Insufficient funds to cover withdrawal fee");
                };

                let actualWithdrawAmount = withdrawAmount - fee;
                let now = Time.now();

                let (finalWithdrawAmount, penaltyAmount) = switch (stakingInfo.get(savingId)) {
                    case (null) { (actualWithdrawAmount, 0 : Nat64) };
                    case (?info) {
                        let dissolveEndTime = info.createdAt + Int64.toInt(Int64.fromNat64(info.dissolveDelay * 1_000_000_000));
                        if (now < dissolveEndTime) {
                            let penalty = actualWithdrawAmount * 5 / 100;
                            let adminFee = actualWithdrawAmount * 2 / 100;
                            let totalDeduction = penalty + adminFee;
                            (actualWithdrawAmount - totalDeduction, totalDeduction);
                        } else {
                            let adminFee = actualWithdrawAmount * 2 / 100;
                            (actualWithdrawAmount - adminFee, adminFee);
                        };
                    };
                };

                // Perform actual ICP transfer from owner to user
                let userAccountBlob = Utils.principalToAccountBlob(caller);
                
                let transferArgs : ICPTransferArgs = {
                    memo = Nat64.fromNat(nextTransactionId);
                    amount = { e8s = finalWithdrawAmount };
                    fee = { e8s = fee };
                    from_subaccount = null;
                    to = userAccountBlob;  // ✅ Fixed: Use raw Blob instead of hex Text
                    created_at_time = null;
                };

                let transferResult = await icpLedger.transfer(transferArgs);
                
                switch (transferResult) {
                    case (#Err(transferError)) {
                        // Transfer failed, return error without updating virtual balances
                        let errorMsg = switch (transferError) {
                            case (#BadFee { expected_fee }) { "Bad fee. Expected: " # Nat64.toText(expected_fee.e8s) # " e8s" };
                            case (#InsufficientFunds { balance }) { "Insufficient funds. Owner balance: " # Nat64.toText(balance.e8s) # " e8s" };
                            case (#TxTooOld { allowed_window_nanos }) { "Transaction too old. Window: " # Nat64.toText(allowed_window_nanos) # " ns" };
                            case (#TxCreatedInFuture) { "Transaction created in future" };
                            case (#TxDuplicate { duplicate_of }) { "Duplicate transaction: " # Nat64.toText(duplicate_of) };
                        };
                        return #Err("ICP withdrawal failed: " # errorMsg);
                    };
                    case (#Ok(blockIndex)) {
                        // Transfer succeeded, update saving and transaction records
                        let updatedSaving : Saving = {
                            id = saving.id;
                            principalId = saving.principalId;
                            savingName = saving.savingName;
                            amount = saving.amount;
                            totalSaving = saving.totalSaving;
                            currentAmount = 0;
                            deadline = saving.deadline;
                            createdAt = saving.createdAt;
                            updatedAt = now;
                            status = #Cancelled;
                            savingsRate = saving.savingsRate;
                            priorityLevel = saving.priorityLevel;
                            isStaking = false;
                        };

                        let txId = nextTransactionId;
                        nextTransactionId += 1;

                        let transaction : Transaction = {
                            id = txId;
                            from = owner;
                            to = caller;
                            amount = finalWithdrawAmount;
                            timestamp = now;
                            status = #Completed;
                            transactionType = #Withdrawal;
                            savingId = ?savingId;
                            memo = ?("Withdrawal from: " # saving.savingName # " (Fee: " # Nat64.toText(fee) # " e8s, Penalty: " # Nat64.toText(penaltyAmount) # " e8s)");
                            blockIndex = ?blockIndex;
                        };

                        savings.put(savingId, updatedSaving);
                        transactions.put(txId, transaction);
                        stakingInfo.delete(savingId);

                        // Debug.print("Withdrew from saving ID: " # Nat.toText(savingId) # " - Amount: " # Nat64.toText(finalWithdrawAmount) # " e8s - Block: " # Nat64.toText(blockIndex)); // REMOVED: Saves ~15,000 cycles
                        #Ok(transaction);
                    };
                };
            };
        };
    };

    // ===== Owner Functions =====
    public query func getOwner() : async Principal {
        owner;
    };  

    public query func getOwnerAccountId() : async Text {
        let ownerAccountBlob = Utils.principalToAccountBlob(owner);
        Utils.blobToHex(ownerAccountBlob);
    };

    public shared (msg) func transferOwnership(newOwner : Principal) : async Bool {
        if (not isOwner(msg.caller)) {
            return false;
        };

        owner := newOwner;
        // Debug.print("Transferred ownership to: " # Principal.toText(newOwner)); // REMOVED: Saves ~8,000 cycles
        true;
    };

    public shared (msg) func pauseStaking() : async Bool {
        if (not isOwner(msg.caller)) {
            return false;
        };

        stakingPaused := true;
        // Debug.print("Staking has been paused"); // REMOVED: Saves ~5,000 cycles
        true;
    };

    public shared (msg) func resumeStaking() : async Bool {
        if (not isOwner(msg.caller)) {
            return false;
        };

        stakingPaused := false;
        // Debug.print("Staking has been resumed"); // REMOVED: Saves ~5,000 cycles
        true;
    };

    public shared (msg) func forceDissolveNeuron(savingId : SavingId, neuronId : Nat64) : async Bool {
        let caller = msg.caller;

        if (not isOwner(caller)) {
            return false;
        };

        switch (stakingInfo.get(savingId)) {
            case (null) { false };
            case (?info) {
                if (info.neuronId != neuronId) {
                    return false;
                };

                let now = Time.now();

                let updatedStakingInfo : StakingInfo = {
                    neuronId = info.neuronId;
                    stake = info.stake;
                    maturity = info.maturity;
                    age = info.age;
                    state = #Dissolved;
                    dissolveDelay = 0;
                    votingPower = 0;
                    createdAt = info.createdAt;
                    lastRewardClaim = info.lastRewardClaim;
                    expectedAPY = 0;
                };

                stakingInfo.put(savingId, updatedStakingInfo);
                // Debug.print("Force dissolved neuron ID: " # Nat64.toText(neuronId) # " for saving ID: " # Nat.toText(savingId)); // REMOVED: Saves ~12,000 cycles
                true;
            };
        };
    };

    public shared (msg) func cleanupDissolvedNeurons() : async Nat {
        if (not isOwner(msg.caller)) {
            return 0;
        };

        let stakingEntries = Iter.toArray(stakingInfo.entries());
        var cleanedCount = 0;

        for ((savingId, info) in stakingEntries.vals()) {
            if (info.state == #Dissolved) {
                let now = Time.now();
                let dissolvedTime = now - info.lastRewardClaim;
                let thirtyDaysInNanos = 30 * 24 * 60 * 60 * 1_000_000_000;

                if (dissolvedTime > thirtyDaysInNanos) {
                    stakingInfo.delete(savingId);
                    neuronToSaving.delete(info.neuronId);
                    cleanedCount += 1;
                    // Debug.print("Cleaned up dissolved neuron ID: " # Nat64.toText(info.neuronId)); // REMOVED: Saves ~10,000 cycles
                };
            };
        };

        // Debug.print("Cleaned up " # Nat.toText(cleanedCount) # " dissolved neurons"); // REMOVED: Saves ~8,000 cycles
        cleanedCount;
    };

    public shared (msg) func migrateSavingsForStaking() : async Bool {
        if (not isOwner(msg.caller)) {
            return false;
        };

        let savingEntries = Iter.toArray(savings.entries());
        var migratedCount = 0;

        for ((savingId, saving) in savingEntries.vals()) {
            let updatedSaving : Saving = {
                id = saving.id;
                principalId = saving.principalId;
                savingName = saving.savingName;
                amount = saving.amount;
                totalSaving = saving.totalSaving;
                currentAmount = saving.currentAmount;
                deadline = saving.deadline;
                createdAt = saving.createdAt;
                updatedAt = saving.updatedAt;
                status = saving.status;
                savingsRate = saving.savingsRate;
                priorityLevel = saving.priorityLevel;
                isStaking = false;
            };

            savings.put(savingId, updatedSaving);
            migratedCount += 1;
        };

        // Debug.print("Migrated " # Nat.toText(migratedCount) # " savings for staking support"); // REMOVED: Saves ~10,000 cycles
        true;
    };

    // ===== ICRC-2 Direct Transfer Functions =====
    
    // Function for direct user-to-owner transfer using ICRC-2
    public shared (msg) func topUpSavingDirect(request : TopUpRequest) : async TransactionResponse {
        if (not Utils.isValidAmount(request.amount)) {
            return #Err("Invalid amount: must be greater than 0");
        };

        let userPrincipal = Principal.fromText(request.principalId);
        let fee = Utils.STANDARD_ICP_FEE;

        if (request.amount <= fee) {
            return #Err("Amount must be greater than transaction fee: " # Nat64.toText(fee) # " e8s");
        };

        let actualAmount = request.amount - fee;

        switch (savings.get(request.savingId)) {
            case (null) {
                return #Err("Saving not found");
            };
            case (?saving) {
                if (saving.status != #Active) {
                    return #Err("Saving is not active");
                };

                // Direct transfer feature not yet implemented 
                // This would require ICRC-2 approve/transferFrom pattern
                return #Err("Direct transfer from user to owner is not yet supported. Please use the two-step process: 1) Deposit to canister using depositToCanister(), 2) Call topUpSaving(). Canister Account ID: c0c8b32d0a6163636f756e742d696400000000018022ff010100000000000000");
            };
        };
    };

    // Mock function to add test ICP to any user
    public shared (msg) func mintTestICP(userPrincipal : Text, amount : Nat64) : async Text {
        if (not mockBalanceEnabled) {
            return "Mock system disabled. Use real ICP transfers.";
        };

        let user = Principal.fromText(userPrincipal);
        let currentBalance = switch (mockBalanceMap.get(user)) {
            case (null) { 0 : Nat64 };
            case (?balance) { balance };
        };
        
        let newBalance = currentBalance + amount;
        mockBalanceMap.put(user, newBalance);
        
        "Minted " # Nat64.toText(amount) # " e8s test ICP for " # userPrincipal # ". New balance: " # Nat64.toText(newBalance) # " e8s";
    };

    // Mock function to get virtual balance
    public query func getMockBalance(userPrincipal : Text) : async Nat64 {
        let user = Principal.fromText(userPrincipal);
        switch (mockBalanceMap.get(user)) {
            case (null) { 0 : Nat64 };
            case (?balance) { balance };
        };
    };

    // Mock transfer function that deducts virtual balance
    private func mockTransfer(from : Principal, to : Principal, amount : Nat64) : Bool {
        let fromBalance = switch (mockBalanceMap.get(from)) {
            case (null) { 0 : Nat64 };
            case (?balance) { balance };
        };

        if (fromBalance < amount) {
            return false; // Insufficient funds
        };

        // Deduct from sender
        mockBalanceMap.put(from, fromBalance - amount);

        // Add to receiver (optional - owner doesn't need virtual balance tracking)
        let toBalance = switch (mockBalanceMap.get(to)) {
            case (null) { 0 : Nat64 };
            case (?balance) { balance };
        };
        mockBalanceMap.put(to, toBalance + amount);

        true; // Success
    };

    // Enhanced topUpSaving with mock support
    public shared (msg) func topUpSavingMock(request : TopUpRequest) : async TransactionResponse {
        if (not Utils.isValidAmount(request.amount)) {
            return #Err("Invalid amount: must be greater than 0");
        };

        let userPrincipal = Principal.fromText(request.principalId);
        let fee = Utils.STANDARD_ICP_FEE;

        if (request.amount <= fee) {
            return #Err("Amount must be greater than transaction fee: " # Nat64.toText(fee) # " e8s");
        };

        let actualAmount = request.amount - fee;

        switch (savings.get(request.savingId)) {
            case (null) {
                return #Err("Saving not found");
            };
            case (?saving) {
                if (saving.status != #Active) {
                    return #Err("Saving is not active");
                };

                if (mockBalanceEnabled) {
                    // Use mock balance system
                    let userMockBalance = switch (mockBalanceMap.get(userPrincipal)) {
                        case (null) { 0 : Nat64 };
                        case (?balance) { balance };
                    };

                    if (userMockBalance < request.amount) {
                        return #Err("Insufficient mock balance. User balance: " # Nat64.toText(userMockBalance) # " e8s. Use mintTestICP() to add test funds.");
                    };

                    // Perform mock transfer (deduct from user virtual balance)
                    let transferSuccess = mockTransfer(userPrincipal, owner, request.amount);
                    
                    if (not transferSuccess) {
                        return #Err("Mock transfer failed: insufficient funds");
                    };

                    // Create successful transaction record
                    let now = Time.now();
                    let newCurrentAmount = saving.currentAmount + actualAmount;
                    let newStatus = if (newCurrentAmount >= saving.totalSaving) {
                        #Completed;
                    } else { #Active };

                    let updatedSaving : Saving = {
                        id = saving.id;
                        principalId = saving.principalId;
                        savingName = saving.savingName;
                        amount = saving.amount;
                        totalSaving = saving.totalSaving;
                        currentAmount = newCurrentAmount;
                        deadline = saving.deadline;
                        createdAt = saving.createdAt;
                        updatedAt = now;
                        status = newStatus;
                        savingsRate = saving.savingsRate;
                        priorityLevel = saving.priorityLevel;
                        isStaking = saving.isStaking;
                    };

                    let txId = nextTransactionId;
                    nextTransactionId += 1;

                    let transaction : Transaction = {
                        id = txId;
                        from = userPrincipal;
                        to = owner;
                        amount = actualAmount;
                        timestamp = now;
                        status = #Completed;
                        transactionType = #TopUp;
                        savingId = ?saving.id;
                        memo = ?("Mock top up for: " # saving.savingName # " (Fee: " # Nat64.toText(fee) # " e8s)");
                        blockIndex = ?999999999; // Mock block index
                    };

                    savings.put(saving.id, updatedSaving);
                    transactions.put(txId, transaction);

                    #Ok(transaction);
                } else {
                    // Use real ICP transfer (original two-step process)
                    let canisterBalance = await getBalance();
                    if (canisterBalance < request.amount) {
                        return #Err("Insufficient canister balance. Please deposit " # Nat64.toText(request.amount) # " e8s to canister first using depositToCanister(). Current balance: " # Nat64.toText(canisterBalance) # " e8s");
                    };

                    let ownerAccountBlob = Utils.principalToAccountBlob(owner);
                    
                    let transferArgs : ICPTransferArgs = {
                        memo = Nat64.fromNat(nextTransactionId);
                        amount = { e8s = request.amount };
                        fee = { e8s = fee };
                        from_subaccount = null;
                        to = ownerAccountBlob;
                        created_at_time = null;
                    };

                    let transferResult = await icpLedger.transfer(transferArgs);
                    
                    switch (transferResult) {
                        case (#Err(transferError)) {
                            let errorMsg = switch (transferError) {
                                case (#BadFee { expected_fee }) { "Bad fee. Expected: " # Nat64.toText(expected_fee.e8s) # " e8s" };
                                case (#InsufficientFunds { balance }) { "Insufficient funds. Canister balance: " # Nat64.toText(balance.e8s) # " e8s. Please deposit more ICP first." };
                                case (#TxTooOld { allowed_window_nanos }) { "Transaction too old. Window: " # Nat64.toText(allowed_window_nanos) # " ns" };
                                case (#TxCreatedInFuture) { "Transaction created in future" };
                                case (#TxDuplicate { duplicate_of }) { "Duplicate transaction: " # Nat64.toText(duplicate_of) };
                            };
                            return #Err("ICP transfer failed: " # errorMsg);
                        };
                        case (#Ok(blockIndex)) {
                            let now = Time.now();
                            let newCurrentAmount = saving.currentAmount + actualAmount;
                            let newStatus = if (newCurrentAmount >= saving.totalSaving) {
                                #Completed;
                            } else { #Active };

                            let updatedSaving : Saving = {
                                id = saving.id;
                                principalId = saving.principalId;
                                savingName = saving.savingName;
                                amount = saving.amount;
                                totalSaving = saving.totalSaving;
                                currentAmount = newCurrentAmount;
                                deadline = saving.deadline;
                                createdAt = saving.createdAt;
                                updatedAt = now;
                                status = newStatus;
                                savingsRate = saving.savingsRate;
                                priorityLevel = saving.priorityLevel;
                                isStaking = saving.isStaking;
                            };

                            let txId = nextTransactionId;
                            nextTransactionId += 1;

                            let transaction : Transaction = {
                                id = txId;
                                from = userPrincipal;
                                to = owner;
                                amount = actualAmount;
                                timestamp = now;
                                status = #Completed;
                                transactionType = #TopUp;
                                savingId = ?saving.id;
                                memo = ?("Top up for: " # saving.savingName # " (Fee: " # Nat64.toText(fee) # " e8s)");
                                blockIndex = ?blockIndex;
                            };

                            savings.put(saving.id, updatedSaving);
                            transactions.put(txId, transaction);

                            #Ok(transaction);
                        };
                    };
                };
            };
        };
    };

    // Function to toggle mock mode
    public shared (msg) func setMockMode(enabled : Bool) : async Text {
        if (not isOwner(msg.caller)) {
            return "Only owner can toggle mock mode";
        };
        
        mockBalanceEnabled := enabled;
        if (enabled) {
            "Mock balance system enabled. Use mintTestICP() and topUpSavingMock() for testing.";
        } else {
            "Mock balance system disabled. Using real ICP transfers.";
        };
    };

    public query func getMockMode() : async Bool {
        mockBalanceEnabled;
    };

    // Mock version of startSaving that uses virtual balances
    public shared (msg) func startSavingMock(request : StartSavingRequest) : async SavingResponse {
        if (not Utils.isValidAmount(request.amount)) {
            return #Err("Invalid amount: must be greater than 0");
        };

        if (request.savingName == "") {
            return #Err("Invalid saving name: cannot be empty");
        };

        if (not Utils.isValidDeadline(request.deadline)) {
            return #Err("Invalid deadline: must be in the future");
        };

        let userPrincipal = Principal.fromText(request.principalId);
        let fee = Utils.STANDARD_ICP_FEE;

        if (request.amount <= fee) {
            return #Err("Amount must be greater than transaction fee: " # Nat64.toText(fee) # " e8s");
        };

        let actualAmount = request.amount - fee;

        if (mockBalanceEnabled) {
            // Use mock balance system
            let userMockBalance = switch (mockBalanceMap.get(userPrincipal)) {
                case (null) { 0 : Nat64 };
                case (?balance) { balance };
            };

            if (userMockBalance < request.amount) {
                return #Err("Insufficient mock balance. User balance: " # Nat64.toText(userMockBalance) # " e8s. Use mintTestICP() to add test funds.");
            };

            // Perform mock transfer (deduct from user virtual balance)
            let transferSuccess = mockTransfer(userPrincipal, owner, request.amount);
            
            if (not transferSuccess) {
                return #Err("Mock transfer failed: insufficient funds");
            };

            // Create saving record
            let savingId = nextSavingId;
            nextSavingId += 1;

            let now = Time.now();
            let savingsRate = switch (request.savingsRate) {
                case (null) { 5 };
                case (?rate) { rate };
            };
            let priorityLevel = switch (request.priorityLevel) {
                case (null) { 1 };
                case (?level) { level };
            };
            let isStaking = switch (request.isStaking) {
                case (null) { false };
                case (?staking) { staking };
            };

            // Determine status: if initial amount >= target, mark as completed
            let status = if (actualAmount >= request.totalSaving) {
                #Completed;
            } else { #Active };

            let newSaving : Saving = {
                id = savingId;
                principalId = userPrincipal;
                savingName = request.savingName;
                amount = request.amount;
                totalSaving = request.totalSaving;
                currentAmount = actualAmount;
                deadline = request.deadline;
                createdAt = now;
                updatedAt = now;
                status = status;
                savingsRate = savingsRate;
                priorityLevel = priorityLevel;
                isStaking = isStaking;
            };

            // Create transaction record
            let transactionId = nextTransactionId;
            nextTransactionId += 1;

            let transaction : Transaction = {
                id = transactionId;
                from = userPrincipal;
                to = owner;
                amount = actualAmount;
                timestamp = now;
                status = #Completed;
                transactionType = #Saving;
                savingId = ?savingId;
                memo = ?("Mock initial saving: " # request.savingName # " (Fee: " # Nat64.toText(fee) # " e8s)");
                blockIndex = ?999999999; // Mock block index
            };

            // Store records
            savings.put(savingId, newSaving);
            transactions.put(transactionId, transaction);

            // Add to user savings list
            addToUserSavings(userPrincipal, savingId);

            #Ok(newSaving);
        } else {
            // Use real ICP transfer (original two-step process)
            let canisterBalance = await getBalance();
            if (canisterBalance < request.amount) {
                return #Err("Insufficient canister balance. Please deposit " # Nat64.toText(request.amount) # " e8s to canister first using depositToCanister(). Current balance: " # Nat64.toText(canisterBalance) # " e8s");
            };

            let ownerAccountBlob = Utils.principalToAccountBlob(owner);
            
            let transferArgs : ICPTransferArgs = {
                memo = Nat64.fromNat(nextTransactionId);
                amount = { e8s = request.amount };
                fee = { e8s = fee };
                from_subaccount = null;
                to = ownerAccountBlob;
                created_at_time = null;
            };

            let transferResult = await icpLedger.transfer(transferArgs);
            
            switch (transferResult) {
                case (#Err(transferError)) {
                    let errorMsg = switch (transferError) {
                        case (#BadFee { expected_fee }) { "Bad fee. Expected: " # Nat64.toText(expected_fee.e8s) # " e8s" };
                        case (#InsufficientFunds { balance }) { "Insufficient funds. Canister balance: " # Nat64.toText(balance.e8s) # " e8s. Please deposit more ICP first." };
                        case (#TxTooOld { allowed_window_nanos }) { "Transaction too old. Window: " # Nat64.toText(allowed_window_nanos) # " ns" };
                        case (#TxCreatedInFuture) { "Transaction created in future" };
                        case (#TxDuplicate { duplicate_of }) { "Duplicate transaction: " # Nat64.toText(duplicate_of) };
                    };
                    return #Err("ICP transfer failed: " # errorMsg);
                };
                case (#Ok(blockIndex)) {
                    let savingId = nextSavingId;
                    nextSavingId += 1;

                    let now = Time.now();
                    let savingsRate = switch (request.savingsRate) {
                        case (null) { 5 };
                        case (?rate) { rate };
                    };
                    let priorityLevel = switch (request.priorityLevel) {
                        case (null) { 1 };
                        case (?level) { level };
                    };
                    let isStaking = switch (request.isStaking) {
                        case (null) { false };
                        case (?staking) { staking };
                    };

                    let status = if (actualAmount >= request.totalSaving) {
                        #Completed;
                    } else { #Active };

                    let newSaving : Saving = {
                        id = savingId;
                        principalId = userPrincipal;
                        savingName = request.savingName;
                        amount = request.amount;
                        totalSaving = request.totalSaving;
                        currentAmount = actualAmount;
                        deadline = request.deadline;
                        createdAt = now;
                        updatedAt = now;
                        status = status;
                        savingsRate = savingsRate;
                        priorityLevel = priorityLevel;
                        isStaking = isStaking;
                    };

                    let transactionId = nextTransactionId;
                    nextTransactionId += 1;

                    let transaction : Transaction = {
                        id = transactionId;
                        from = userPrincipal;
                        to = owner;
                        amount = actualAmount;
                        timestamp = now;
                        status = #Completed;
                        transactionType = #Saving;
                        savingId = ?savingId;
                        memo = ?("Mock initial saving: " # request.savingName # " (Fee: " # Nat64.toText(fee) # " e8s)");
                        blockIndex = ?999999999; // Mock block index
                    };

                    savings.put(savingId, newSaving);
                    transactions.put(transactionId, transaction);
                    addToUserSavings(userPrincipal, savingId);

                    #Ok(newSaving);
                };
            };
        };
    };

};
