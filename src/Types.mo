import Principal "mo:base/Principal";
import Nat "mo:base/Nat";
import Text "mo:base/Text";
import Time "mo:base/Time";
import Blob "mo:base/Blob";
import Nat64 "mo:base/Nat64";

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
        to : Text;
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
};
