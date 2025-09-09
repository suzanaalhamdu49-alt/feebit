;; title: fee-manager
;; version: 1.0.0
;; summary: Core fee management contract for FeeBit tokenized school payments
;; description: Manages student registration, fee structures, payment processing, and balance tracking

;; traits
;;

;; token definitions
;;

;; constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u401))
(define-constant ERR_NOT_FOUND (err u404))
(define-constant ERR_INSUFFICIENT_BALANCE (err u402))
(define-constant ERR_INVALID_AMOUNT (err u400))
(define-constant ERR_ALREADY_EXISTS (err u409))
(define-constant ERR_PAYMENT_FAILED (err u500))

;; Fee types
(define-constant FEE_TYPE_TUITION u1)
(define-constant FEE_TYPE_MATERIALS u2)
(define-constant FEE_TYPE_ACTIVITIES u3)
(define-constant FEE_TYPE_TRANSPORTATION u4)
(define-constant FEE_TYPE_LATE_PENALTY u5)

;; data vars
(define-data-var next-student-id uint u1)
(define-data-var school-admin principal CONTRACT_OWNER)
(define-data-var total-students uint u0)
(define-data-var total-fees-collected uint u0)

;; data maps
;; Student information mapping
(define-map students
  { student-id: uint }
  {
    student-name: (string-ascii 50),
    parent-wallet: principal,
    grade-level: uint,
    enrollment-date: uint,
    active: bool
  }
)

;; Student fee balances by fee type
(define-map student-balances
  { student-id: uint, fee-type: uint }
  { balance: uint, last-payment: uint }
)

;; Fee structure definitions
(define-map fee-structures
  { grade-level: uint, fee-type: uint }
  { amount: uint, due-date: uint, description: (string-ascii 100) }
)

;; Payment history tracking
(define-map payment-history
  { payment-id: uint }
  {
    student-id: uint,
    fee-type: uint,
    amount: uint,
    payment-date: uint,
    payer: principal
  }
)

;; School revenue tracking
(define-map school-revenue
  { fee-type: uint, period: uint }
  { total-collected: uint, payment-count: uint }
)

;; public functions

;; Register a new student
(define-public (register-student (student-name (string-ascii 50)) (parent-wallet principal) (grade-level uint))
  (let
    (
      (student-id (var-get next-student-id))
      (current-block burn-block-height)
    )
    (asserts! (is-eq tx-sender (var-get school-admin)) ERR_UNAUTHORIZED)
    (asserts! (> (len student-name) u0) ERR_INVALID_AMOUNT)
    (asserts! (and (>= grade-level u1) (<= grade-level u12)) ERR_INVALID_AMOUNT)
    
    ;; Create student record
    (map-set students
      { student-id: student-id }
      {
        student-name: student-name,
        parent-wallet: parent-wallet,
        grade-level: grade-level,
        enrollment-date: current-block,
        active: true
      }
    )
    
    ;; Initialize student balances for all fee types
    (map-set student-balances { student-id: student-id, fee-type: FEE_TYPE_TUITION } { balance: u0, last-payment: u0 })
    (map-set student-balances { student-id: student-id, fee-type: FEE_TYPE_MATERIALS } { balance: u0, last-payment: u0 })
    (map-set student-balances { student-id: student-id, fee-type: FEE_TYPE_ACTIVITIES } { balance: u0, last-payment: u0 })
    (map-set student-balances { student-id: student-id, fee-type: FEE_TYPE_TRANSPORTATION } { balance: u0, last-payment: u0 })
    (map-set student-balances { student-id: student-id, fee-type: FEE_TYPE_LATE_PENALTY } { balance: u0, last-payment: u0 })
    
    ;; Update counters
    (var-set next-student-id (+ student-id u1))
    (var-set total-students (+ (var-get total-students) u1))
    
    (ok student-id)
  )
)

;; Set fee structure for a grade level and fee type
(define-public (set-fee-structure (grade-level uint) (fee-type uint) (amount uint) (due-date uint) (description (string-ascii 100)))
  (begin
    (asserts! (is-eq tx-sender (var-get school-admin)) ERR_UNAUTHORIZED)
    (asserts! (and (>= grade-level u1) (<= grade-level u12)) ERR_INVALID_AMOUNT)
    (asserts! (and (>= fee-type u1) (<= fee-type u5)) ERR_INVALID_AMOUNT)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    
    (map-set fee-structures
      { grade-level: grade-level, fee-type: fee-type }
      { amount: amount, due-date: due-date, description: description }
    )
    
    (ok true)
  )
)

;; Process fee payment using tokens from fee-token contract
(define-public (pay-school-fees (student-id uint) (fee-type uint) (amount uint))
  (let
    (
      (student-data (unwrap! (map-get? students { student-id: student-id }) ERR_NOT_FOUND))
      (current-balance (default-to { balance: u0, last-payment: u0 } 
                                   (map-get? student-balances { student-id: student-id, fee-type: fee-type })))
      (parent-wallet (get parent-wallet student-data))
      (current-block burn-block-height)
    )
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (asserts! (and (>= fee-type u1) (<= fee-type u5)) ERR_INVALID_AMOUNT)
    (asserts! (get active student-data) ERR_NOT_FOUND)
    
    ;; Verify the caller is the parent or school admin
    (asserts! (or (is-eq tx-sender parent-wallet) (is-eq tx-sender (var-get school-admin))) ERR_UNAUTHORIZED)
    
    ;; Note: In production, this would call fee-token contract to verify and deduct tokens
    ;; (try! (contract-call? .fee-token deduct-fee-tokens tx-sender amount))
    ;; For now, we'll assume token validation is handled externally
    
    ;; Update student balance
    (map-set student-balances
      { student-id: student-id, fee-type: fee-type }
      {
        balance: (+ (get balance current-balance) amount),
        last-payment: current-block
      }
    )
    
    ;; Record payment history
    (map-set payment-history
      { payment-id: (+ (var-get total-fees-collected) u1) }
      {
        student-id: student-id,
        fee-type: fee-type,
        amount: amount,
        payment-date: current-block,
        payer: tx-sender
      }
    )
    
    ;; Update revenue tracking
    (let
      (
        (current-period (/ current-block u144)) ;; Roughly daily periods
        (current-revenue (default-to { total-collected: u0, payment-count: u0 }
                                      (map-get? school-revenue { fee-type: fee-type, period: current-period })))
      )
      (map-set school-revenue
        { fee-type: fee-type, period: current-period }
        {
          total-collected: (+ (get total-collected current-revenue) amount),
          payment-count: (+ (get payment-count current-revenue) u1)
        }
      )
    )
    
    ;; Update total fees collected
    (var-set total-fees-collected (+ (var-get total-fees-collected) amount))
    
    (ok amount)
  )
)

;; Update student status (activate/deactivate)
(define-public (update-student-status (student-id uint) (active bool))
  (let
    (
      (student-data (unwrap! (map-get? students { student-id: student-id }) ERR_NOT_FOUND))
    )
    (asserts! (is-eq tx-sender (var-get school-admin)) ERR_UNAUTHORIZED)
    
    (map-set students
      { student-id: student-id }
      (merge student-data { active: active })
    )
    
    (ok true)
  )
)

;; Transfer school admin role
(define-public (transfer-admin-role (new-admin principal))
  (begin
    (asserts! (is-eq tx-sender (var-get school-admin)) ERR_UNAUTHORIZED)
    (var-set school-admin new-admin)
    (ok true)
  )
)

;; read only functions

;; Get student information
(define-read-only (get-student-info (student-id uint))
  (map-get? students { student-id: student-id })
)

;; Get student balance for specific fee type
(define-read-only (get-student-balance (student-id uint) (fee-type uint))
  (map-get? student-balances { student-id: student-id, fee-type: fee-type })
)

;; Get fee structure for grade level and fee type
(define-read-only (get-fee-structure (grade-level uint) (fee-type uint))
  (map-get? fee-structures { grade-level: grade-level, fee-type: fee-type })
)

;; Get payment history by payment ID
(define-read-only (get-payment-history (payment-id uint))
  (map-get? payment-history { payment-id: payment-id })
)

;; Get school revenue for specific fee type and period
(define-read-only (get-school-revenue (fee-type uint) (period uint))
  (map-get? school-revenue { fee-type: fee-type, period: period })
)

;; Get total statistics
(define-read-only (get-school-stats)
  {
    total-students: (var-get total-students),
    total-fees-collected: (var-get total-fees-collected),
    school-admin: (var-get school-admin),
    next-student-id: (var-get next-student-id)
  }
)

;; Check if student exists and is active
(define-read-only (is-student-active (student-id uint))
  (match (map-get? students { student-id: student-id })
    student-data (get active student-data)
    false
  )
)

;; Get student's parent wallet
(define-read-only (get-student-parent (student-id uint))
  (match (map-get? students { student-id: student-id })
    student-data (some (get parent-wallet student-data))
    none
  )
)

;; private functions

;; Validate fee type
(define-private (is-valid-fee-type (fee-type uint))
  (and (>= fee-type u1) (<= fee-type u5))
)

;; Calculate late penalty based on days overdue
(define-private (calculate-late-penalty (due-date uint) (current-date uint) (base-amount uint))
  (if (> current-date due-date)
      (let
        (
          (days-overdue (- current-date due-date))
          (penalty-rate u5) ;; 5% penalty rate
        )
        (/ (* base-amount penalty-rate days-overdue) u10000)
      )
      u0
  )
)
