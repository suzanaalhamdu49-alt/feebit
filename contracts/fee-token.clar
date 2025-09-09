;; title: fee-token
;; version: 1.0.0
;; summary: Token system contract for FeeBit prepaid school fee management
;; description: Handles fee token minting, transfers, verification, and deduction for school payments

;; traits
;; (impl-trait 'SP3FBR2AGK5H9QBDH3EEN6DF8EK8JY7RX8QJ5SVTE.sip-010-trait-ft-standard.sip-010-trait)

;; token definitions
(define-fungible-token fee-bits)

;; constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u401))
(define-constant ERR_NOT_FOUND (err u404))
(define-constant ERR_INSUFFICIENT_BALANCE (err u402))
(define-constant ERR_INVALID_AMOUNT (err u400))
(define-constant ERR_TOKEN_TRANSFER_FAILED (err u500))
(define-constant ERR_MINT_FAILED (err u501))
(define-constant ERR_BURN_FAILED (err u502))

;; Token configuration
(define-constant TOKEN_NAME "FeeBit Token")
(define-constant TOKEN_SYMBOL "FBIT")
(define-constant TOKEN_DECIMALS u6)
(define-constant TOKEN_URI u"https://feebit.io/token-metadata.json")

;; Conversion rates (1 USD = 100 fee bits)
(define-constant USD_TO_FEEBIT_RATE u100)
(define-constant MIN_PURCHASE_AMOUNT u1000) ;; $10 minimum
(define-constant MAX_PURCHASE_AMOUNT u1000000) ;; $10,000 maximum

;; data vars
(define-data-var token-admin principal CONTRACT_OWNER)
(define-data-var total-supply uint u0)
(define-data-var minting-enabled bool true)
(define-data-var transfer-fee uint u0) ;; Fee in basis points (0 = no fee)
(define-data-var next-purchase-id uint u1)

;; data maps
;; Track parent account balances and purchase history
(define-map parent-accounts
  { parent-wallet: principal }
  {
    total-purchased: uint,
    total-spent: uint,
    last-purchase: uint,
    purchase-count: uint,
    verified: bool
  }
)

;; Purchase transaction history
(define-map purchase-history
  { purchase-id: uint }
  {
    buyer: principal,
    amount: uint,
    fee-bits-minted: uint,
    purchase-date: uint,
    payment-method: (string-ascii 20)
  }
)

;; Fee token allowances for spending
(define-map token-allowances
  { owner: principal, spender: principal }
  { allowance: uint, expiry-block: uint }
)

;; Daily spending limits for parents
(define-map daily-limits
  { parent-wallet: principal, date: uint }
  { spent-today: uint, limit: uint }
)

;; Authorized contracts that can deduct tokens
(define-map authorized-contracts
  { contract-address: principal }
  { authorized: bool, max-deduction: uint }
)

;; public functions

;; Purchase fee tokens (minting new tokens)
(define-public (purchase-fee-tokens (amount uint))
  (let
    (
      (current-block burn-block-height)
      (purchase-id (var-get next-purchase-id))
      (parent-data (default-to
        { total-purchased: u0, total-spent: u0, last-purchase: u0, purchase-count: u0, verified: false }
        (map-get? parent-accounts { parent-wallet: tx-sender })
      ))
    )
    (asserts! (var-get minting-enabled) ERR_UNAUTHORIZED)
    (asserts! (>= amount MIN_PURCHASE_AMOUNT) ERR_INVALID_AMOUNT)
    (asserts! (<= amount MAX_PURCHASE_AMOUNT) ERR_INVALID_AMOUNT)
    
    ;; Mint fee tokens to the buyer
    (try! (ft-mint? fee-bits amount tx-sender))
    
    ;; Update parent account data
    (map-set parent-accounts
      { parent-wallet: tx-sender }
      {
        total-purchased: (+ (get total-purchased parent-data) amount),
        total-spent: (get total-spent parent-data),
        last-purchase: current-block,
        purchase-count: (+ (get purchase-count parent-data) u1),
        verified: (get verified parent-data)
      }
    )
    
    ;; Record purchase history
    (map-set purchase-history
      { purchase-id: purchase-id }
      {
        buyer: tx-sender,
        amount: amount,
        fee-bits-minted: amount,
        purchase-date: current-block,
        payment-method: "STX"
      }
    )
    
    ;; Update counters
    (var-set next-purchase-id (+ purchase-id u1))
    (var-set total-supply (+ (var-get total-supply) amount))
    
    (ok amount)
  )
)

;; Deduct fee tokens (called by authorized contracts like fee-manager)
(define-public (deduct-fee-tokens (from principal) (amount uint))
  (let
    (
      (current-balance (ft-get-balance fee-bits from))
      (current-block burn-block-height)
      (parent-data (default-to
        { total-purchased: u0, total-spent: u0, last-purchase: u0, purchase-count: u0, verified: false }
        (map-get? parent-accounts { parent-wallet: from })
      ))
      (contract-auth (default-to
        { authorized: false, max-deduction: u0 }
        (map-get? authorized-contracts { contract-address: tx-sender })
      ))
    )
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (asserts! (>= current-balance amount) ERR_INSUFFICIENT_BALANCE)
    (asserts! (get authorized contract-auth) ERR_UNAUTHORIZED)
    (asserts! (<= amount (get max-deduction contract-auth)) ERR_UNAUTHORIZED)
    
    ;; Check daily spending limit
    (let
      (
        (today (/ current-block u144)) ;; Approximate daily blocks
        (daily-data (default-to
          { spent-today: u0, limit: u50000 } ;; Default $500 daily limit
          (map-get? daily-limits { parent-wallet: from, date: today })
        ))
      )
      (asserts! (<= (+ (get spent-today daily-data) amount) (get limit daily-data)) ERR_INSUFFICIENT_BALANCE)
      
      ;; Update daily spending
      (map-set daily-limits
        { parent-wallet: from, date: today }
        {
          spent-today: (+ (get spent-today daily-data) amount),
          limit: (get limit daily-data)
        }
      )
    )
    
    ;; Burn the tokens (remove from circulation)
    (try! (ft-burn? fee-bits amount from))
    
    ;; Update parent account spending
    (map-set parent-accounts
      { parent-wallet: from }
      (merge parent-data { total-spent: (+ (get total-spent parent-data) amount) })
    )
    
    ;; Update total supply
    (var-set total-supply (- (var-get total-supply) amount))
    
    (ok amount)
  )
)

;; Transfer tokens between accounts
(define-public (transfer (amount uint) (from principal) (to principal) (memo (optional (buff 34))))
  (let
    (
      (transfer-fee-amount (calculate-transfer-fee amount))
      (net-amount (- amount transfer-fee-amount))
    )
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (asserts! (>= (ft-get-balance fee-bits from) amount) ERR_INSUFFICIENT_BALANCE)
    
    ;; Execute the transfer
    (try! (ft-transfer? fee-bits net-amount from to))
    
    ;; Handle transfer fee (if any)
    (if (> transfer-fee-amount u0)
        (try! (ft-transfer? fee-bits transfer-fee-amount from (var-get token-admin)))
        true
    )
    
    (print { action: "transfer", from: from, to: to, amount: amount, fee: transfer-fee-amount, memo: memo })
    (ok true)
  )
)

;; Set daily spending limit for a parent account
(define-public (set-daily-limit (limit uint))
  (let
    (
      (today (/ burn-block-height u144))
    )
    (asserts! (> limit u0) ERR_INVALID_AMOUNT)
    (asserts! (<= limit u100000) ERR_INVALID_AMOUNT) ;; Max $1000 per day
    
    (map-set daily-limits
      { parent-wallet: tx-sender, date: today }
      { spent-today: u0, limit: limit }
    )
    
    (ok true)
  )
)

;; Authorize contract to deduct tokens
(define-public (authorize-contract (contract-address principal) (max-deduction uint))
  (begin
    (asserts! (is-eq tx-sender (var-get token-admin)) ERR_UNAUTHORIZED)
    (asserts! (> max-deduction u0) ERR_INVALID_AMOUNT)
    
    (map-set authorized-contracts
      { contract-address: contract-address }
      { authorized: true, max-deduction: max-deduction }
    )
    
    (ok true)
  )
)

;; Revoke contract authorization
(define-public (revoke-contract-auth (contract-address principal))
  (begin
    (asserts! (is-eq tx-sender (var-get token-admin)) ERR_UNAUTHORIZED)
    
    (map-set authorized-contracts
      { contract-address: contract-address }
      { authorized: false, max-deduction: u0 }
    )
    
    (ok true)
  )
)

;; Admin function to enable/disable minting
(define-public (set-minting-enabled (enabled bool))
  (begin
    (asserts! (is-eq tx-sender (var-get token-admin)) ERR_UNAUTHORIZED)
    (var-set minting-enabled enabled)
    (ok enabled)
  )
)

;; Set transfer fee (basis points)
(define-public (set-transfer-fee (fee uint))
  (begin
    (asserts! (is-eq tx-sender (var-get token-admin)) ERR_UNAUTHORIZED)
    (asserts! (<= fee u1000) ERR_INVALID_AMOUNT) ;; Max 10% fee
    (var-set transfer-fee fee)
    (ok fee)
  )
)

;; Transfer admin role
(define-public (transfer-admin (new-admin principal))
  (begin
    (asserts! (is-eq tx-sender (var-get token-admin)) ERR_UNAUTHORIZED)
    (var-set token-admin new-admin)
    (ok true)
  )
)

;; read only functions

;; SIP-010 standard functions
(define-read-only (get-name)
  (ok TOKEN_NAME)
)

(define-read-only (get-symbol)
  (ok TOKEN_SYMBOL)
)

(define-read-only (get-decimals)
  (ok TOKEN_DECIMALS)
)

(define-read-only (get-balance (who principal))
  (ok (ft-get-balance fee-bits who))
)

(define-read-only (get-total-supply)
  (ok (var-get total-supply))
)

(define-read-only (get-token-uri)
  (ok (some TOKEN_URI))
)

;; Custom read-only functions

;; Get parent account information
(define-read-only (get-parent-account (parent-wallet principal))
  (map-get? parent-accounts { parent-wallet: parent-wallet })
)

;; Get purchase history by purchase ID
(define-read-only (get-purchase-history (purchase-id uint))
  (map-get? purchase-history { purchase-id: purchase-id })
)

;; Get daily spending info
(define-read-only (get-daily-limit (parent-wallet principal) (date uint))
  (map-get? daily-limits { parent-wallet: parent-wallet, date: date })
)

;; Check if contract is authorized
(define-read-only (is-contract-authorized (contract-address principal))
  (default-to false
    (get authorized (map-get? authorized-contracts { contract-address: contract-address }))
  )
)

;; Get token admin
(define-read-only (get-token-admin)
  (var-get token-admin)
)

;; Check if minting is enabled
(define-read-only (is-minting-enabled)
  (var-get minting-enabled)
)

;; Get current transfer fee
(define-read-only (get-transfer-fee)
  (var-get transfer-fee)
)

;; Calculate USD equivalent of fee bits
(define-read-only (fee-bits-to-usd (token-amount uint))
  (/ token-amount USD_TO_FEEBIT_RATE)
)

;; Calculate fee bits from USD amount
(define-read-only (usd-to-fee-bits (usd-amount uint))
  (* usd-amount USD_TO_FEEBIT_RATE)
)

;; private functions

;; Calculate transfer fee based on amount and current fee rate
(define-private (calculate-transfer-fee (amount uint))
  (if (> (var-get transfer-fee) u0)
      (/ (* amount (var-get transfer-fee)) u10000)
      u0
  )
)

;; Validate transfer parameters
(define-private (is-valid-transfer (amount uint) (from principal) (to principal))
  (and
    (> amount u0)
    (not (is-eq from to))
    (>= (ft-get-balance fee-bits from) amount)
  )
)
