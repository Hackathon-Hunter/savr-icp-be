import Principal "mo:base/Principal";
import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Nat8 "mo:base/Nat8";
import Nat64 "mo:base/Nat64";
import Text "mo:base/Text";
import Nat "mo:base/Nat";
import Iter "mo:base/Iter";
import Int "mo:base/Int";
import Float "mo:base/Float";
import Time "mo:base/Time";

module {
    // ===== Constants =====
    public let STANDARD_ICP_FEE : Nat64 = 10_000; // 0.0001 ICP in e8s
    public let E8S_PER_ICP : Nat64 = 100_000_000; // 10^8
    
    // ===== Conversion Functions =====
    public func icpToE8s(icp : Float) : Nat64 {
        let value = Float.toInt(icp * 100_000_000.0);
        Nat64.fromNat(Int.abs(value));
    };

    public func e8sToIcp(e8s : Nat64) : Float {
        Float.fromInt(Nat64.toNat(e8s)) / 100_000_000.0;
    };

    public func formatIcp(e8s : Nat64) : Text {
        let icp = e8sToIcp(e8s);
        let formatted = Float.toText(icp);
        
        // Check if we need to add trailing zeros
        if (not Text.contains(formatted, #char '.')) {
            return formatted # ".00";
        };
        
        let parts = Iter.toArray(Text.split(formatted, #char '.'));
        if (parts.size() != 2) {
            return formatted; // Just return as is if unexpected format
        };
        
        let decimalPart = parts[1];
        if (decimalPart.size() == 1) {
            return formatted # "0"; // Add one trailing zero
        } else if (decimalPart.size() > 8) {
            // Trim to 8 decimal places - simpler implementation
            let chars = Iter.toArray(Text.toIter(decimalPart));
            var trimmed = "";
            for (i in Iter.range(0, Nat.min(7, chars.size() - 1))) {
                trimmed := trimmed # Text.fromChar(chars[i]);
            };
            return parts[0] # "." # trimmed;
        };
        
        formatted;
    };

    // ===== Validation Functions =====
    public func isValidAmount(amount : Nat64) : Bool {
        amount > 0;
    };

    public func isValidDeadline(deadline : Int) : Bool {
        deadline > Time.now();
    };

    // ===== Account Utilities =====
    // Convert a text representation of a principal to an Account
    public func principalToAccount(principalText : Text) : { owner : Principal; subaccount : ?Blob } {
        {
            owner = Principal.fromText(principalText);
            subaccount = null;
        };
    };
} 