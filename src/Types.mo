import Principal "mo:base/Principal";
import Nat "mo:base/Nat";
import Text "mo:base/Text";
import Blob "mo:base/Blob";
import Nat64 "mo:base/Nat64";
import Float "mo:base/Float";

module {
    // ===== ICRC-1 Standard Types =====
    public type Account = {
        owner : Principal;
        subaccount : ?Blob;
    };

    public type TransferArgs = {
        from_subaccount : ?Blob;
        to : Account;
        amount : Nat;
        fee : ?Nat;
        memo : ?Blob;
        created_at_time : ?Nat64;
    };

    public type TransferError = {
        #BadFee : { expected_fee : Nat };
        #BadBurn : { min_burn_amount : Nat };
        #InsufficientFunds : { balance : Nat };
        #TooOld;
        #CreatedInFuture : { ledger_time : Nat64 };
        #Duplicate : { duplicate_of : Nat };
        #TemporarilyUnavailable;
        #GenericError : { error_code : Nat; message : Text };
    };

    public type TransferResult = {
        #Ok : Nat;
        #Err : TransferError;
    };

    // ===== ICP Ledger Types =====
    public type ICP = {
        e8s : Nat64;
    };

    public type ICPTransferArgs = {
        memo : Nat64;
        amount : ICP;
        fee : ICP;
        from_subaccount : ?Blob;
        to : Blob;  // ✅ Fixed: Changed from Text to Blob (account ID)
        created_at_time : ?{ timestamp_nanos : Nat64 };
    };

    public type ICPTransferResult = {
        #Ok : Nat64;
        #Err : ICPTransferError;
    };

    public type ICPTransferError = {
        #BadFee : { expected_fee : ICP };
        #InsufficientFunds : { balance : ICP };
        #TxTooOld : { allowed_window_nanos : Nat64 };
        #TxCreatedInFuture;
        #TxDuplicate : { duplicate_of : Nat64 };
    };

    // ===== Saving Types =====
    public type SavingId = Nat;

    public type Saving = {
        id : SavingId;
        principalId : Principal;
        savingName : Text;
        amount : Nat64; // e8s format
        totalSaving : Nat64; // target amount in e8s
        currentAmount : Nat64; // current saved amount in e8s
        deadline : Int; // timestamp
        createdAt : Int;
        updatedAt : Int;
        status : SavingStatus;
        savingsRate : Nat; // percentage rate
        priorityLevel : Nat; // priority level (1-10 or similar)
        isStaking : Bool; // whether this saving is staking
    };

    public type SavingStatus = {
        #Active;
        #Completed;
        #Cancelled;
    };

    // ===== Transaction Types =====
    public type TransactionId = Nat;

    public type TransactionStatus = {
        #Pending;
        #Completed;
        #Failed : Text;
    };

    public type TransactionType = {
        #Saving;
        #TopUp;
        #Withdrawal;
        #Staking;
        #Unstaking;
        #StakingReward;
        #Deposit; // User deposits to canister
    };

    public type Transaction = {
        id : TransactionId;
        from : Principal;
        to : Principal;
        amount : Nat64; // e8s format
        timestamp : Int;
        status : TransactionStatus;
        transactionType : TransactionType;
        savingId : ?SavingId;
        memo : ?Text;
        blockIndex : ?Nat64; // ICP ledger block index
    };

    // ===== Staking Types =====
    public type NeuronState = {
        #Locked;
        #Dissolving;
        #Dissolved;
    };

    public type StakingInfo = {
        neuronId : Nat64;
        stake : Nat64; // Amount staked in e8s
        maturity : Nat64; // Accumulated rewards in e8s
        age : Int; // Age of the neuron in nanoseconds
        state : NeuronState;
        dissolveDelay : Nat64; // Dissolve delay in seconds
        votingPower : Nat64; // Voting power
        createdAt : Int; // Creation timestamp
        lastRewardClaim : Int; // Last reward claim timestamp
        expectedAPY : Float; // Expected annual percentage yield
    };

    public type StakeICPRequest = {
        principalId : Text;
        savingId : SavingId;
        amount : Nat64; // Amount to stake in e8s
        dissolveDelay : Nat64; // Dissolve delay in seconds
    };

    public type StakeICPResponse = {
        neuronId : Nat64;
        stake : Nat64;
        dissolveDelay : Nat64;
        expectedRewards : Nat64;
    };

    public type UnstakeRequest = {
        principalId : Text;
        savingId : SavingId;
        neuronId : Nat64;
    };

    public type StakingRewards = {
        totalRewards : Nat64;
        annualizedReturn : Float;
        lastRewardDate : Int;
        pendingRewards : Nat64;
    };

    public type StakeResponse = {
        #Ok : StakeICPResponse;
        #Err : Text;
    };

    public type UnstakeResponse = {
        #Ok : Bool;
        #Err : Text;
    };

    // ===== Request Types =====
    public type StartSavingRequest = {
        amount : Nat64; // e8s format
        savingName : Text;
        deadline : Int; // timestamp
        principalId : Text;
        totalSaving : Nat64; // e8s format
        savingsRate : ?Nat; // optional percentage rate
        priorityLevel : ?Nat; // optional priority level (1-10 or similar)
        isStaking : ?Bool; // optional whether this saving is staking
    };

    public type TopUpRequest = {
        principalId : Text;
        savingId : SavingId;
        amount : Nat64; // e8s format
    };

    public type UpdateSavingRequest = {
        savingId : SavingId;
        savingName : ?Text; // optional new saving name
        deadline : ?Int; // optional new deadline timestamp
        totalSaving : ?Nat64; // optional new target amount in e8s format
        savingsRate : ?Nat; // optional percentage rate
        priorityLevel : ?Nat; // optional priority level (1-10 or similar)
        isStaking : ?Bool; // optional whether this saving is staking
    };

    // ===== Extended Types =====
    public type TopUpHistory = {
        date : Int;
        amount : Nat64;
    };

    public type SavingWithHistory = {
        id : SavingId;
        principalId : Principal;
        savingName : Text;
        amount : Nat64; // e8s format
        totalSaving : Nat64; // target amount in e8s
        currentAmount : Nat64; // current saved amount in e8s
        deadline : Int; // timestamp
        createdAt : Int;
        updatedAt : Int;
        status : SavingStatus;
        savingsRate : Nat; // percentage rate
        priorityLevel : Nat; // priority level (1-10 or similar)
        isStaking : Bool; // whether this saving is staking
        topUpHistory : [TopUpHistory];
    };

    // ===== Response Types =====
    public type Result<T, E> = {
        #Ok : T;
        #Err : E;
    };

    public type SavingResponse = Result<Saving, Text>;
    public type TransactionResponse = Result<Transaction, Text>;
    public type SavingWithHistoryResponse = Result<SavingWithHistory, Text>;

    // ===== HTTP OutCall Types =====
    public type HttpRequestArgs = {
        url : Text;
        max_response_bytes : ?Nat64;
        headers : [{ name : Text; value : Text }];
        body : ?[Nat8];
        method : { #get; #head; #post };
        transform : ?{
            function : shared query { response : HttpResponse; context : Blob } -> async HttpResponse;
            context : Blob;
        };
    };

    public type HttpResponsePayload = {
        status : Nat;
        headers : [{ name : Text; value : Text }];
        body : [Nat8];
    };

    public type HttpResponse = HttpResponsePayload;

    // ===== Cycles Management Types =====
    public type CyclesInfo = {
        balance : Nat;
        available : Nat;
        threshold : Nat;
        needsTopUp : Bool;
        estimatedRemainingDays : ?Float;
        cyclesPerDay : ?Nat;
    };
};
