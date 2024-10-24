;; Bitcoin-Backed Stablecoin System
;; Version: 1.0
;; A decentralized stablecoin system backed by Bitcoin collateral

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-insufficient-collateral (err u101))
(define-constant err-below-mcr (err u102))
(define-constant err-already-initialized (err u103))
(define-constant err-not-initialized (err u104))
(define-constant err-low-balance (err u105))
(define-constant err-invalid-price (err u106))
(define-constant err-emergency-shutdown (err u107))

;; Data Variables
(define-data-var minimum-collateral-ratio uint u150) ;; 150% collateralization ratio
(define-data-var liquidation-ratio uint u120) ;; 120% liquidation threshold
(define-data-var stability-fee uint u2) ;; 2% annual stability fee
(define-data-var initialized bool false)
(define-data-var emergency-shutdown bool false)
(define-data-var last-price uint u0) ;; Latest BTC/USD price
(define-data-var price-valid bool false)
(define-data-var governance-token principal 'SP000000000000000000002Q6VF78.governance-token)

;; Storage
(define-map vaults
    principal
    {
        collateral: uint,
        debt: uint,
        last-fee-timestamp: uint
    }
)

(define-map liquidators principal bool)
(define-map price-oracles principal bool)

;; Public Functions
(define-public (initialize (btc-price uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (not (var-get initialized)) err-already-initialized)
        (var-set last-price btc-price)
        (var-set price-valid true)
        (var-set initialized true)
        (ok true)
    )
)

(define-public (create-vault (collateral-amount uint))
    (let (
        (existing-vault (default-to 
            {
                collateral: u0,
                debt: u0,
                last-fee-timestamp: (unwrap-panic (get-block-info? time u0))
            }
            (map-get? vaults tx-sender)
        ))
    )
    (begin
        (asserts! (var-get initialized) err-not-initialized)
        (asserts! (not (var-get emergency-shutdown)) err-emergency-shutdown)
        (try! (stx-transfer? collateral-amount tx-sender (as-contract tx-sender)))
        (map-set vaults tx-sender 
            (merge existing-vault {
                collateral: (+ collateral-amount (get collateral existing-vault))
            })
        )
        (ok true)
    ))
)

(define-public (repay-debt (amount uint))
    (let (
        (vault (unwrap! (map-get? vaults tx-sender) err-low-balance))
        (current-debt (get debt vault))
    )
    (begin
        (asserts! (var-get initialized) err-not-initialized)
        (asserts! (>= current-debt amount) err-low-balance)
        (map-set vaults tx-sender
            (merge vault {
                debt: (- current-debt amount)
            })
        )
        (ok true)
    ))
)

(define-public (withdraw-collateral (amount uint))
    (let (
        (vault (unwrap! (map-get? vaults tx-sender) err-low-balance))
        (current-collateral (get collateral vault))
        (current-debt (get debt vault))
        (new-collateral (- current-collateral amount))
        (collateral-value (* new-collateral (var-get last-price)))
    )
    (begin
        (asserts! (var-get initialized) err-not-initialized)
        (asserts! (not (var-get emergency-shutdown)) err-emergency-shutdown)
        (asserts! (var-get price-valid) err-invalid-price)
        (asserts! (>= current-collateral amount) err-low-balance)
        ;; Check if withdrawal maintains minimum collateral ratio
        (asserts! (or
            (is-eq current-debt u0)
            (>= (* collateral-value u100)
                (* current-debt (var-get minimum-collateral-ratio))))
            err-below-mcr)
        (try! (as-contract (stx-transfer? amount (as-contract tx-sender) tx-sender)))
        (map-set vaults tx-sender
            (merge vault {
                collateral: new-collateral
            })
        )
        (ok true)
    ))
)

;; Liquidation Functions
(define-public (liquidate (vault-owner principal))
    (let (
        (vault (unwrap! (map-get? vaults vault-owner) err-low-balance))
        (collateral (get collateral vault))
        (debt (get debt vault))
        (collateral-value (* collateral (var-get last-price)))
    )
    (begin
        (asserts! (var-get initialized) err-not-initialized)
        (asserts! (var-get price-valid) err-invalid-price)
        (asserts! (is-authorized-liquidator tx-sender) err-owner-only)
        ;; Check if vault is below liquidation ratio
        (asserts! (< (* collateral-value u100)
            (* debt (var-get liquidation-ratio)))
            err-insufficient-collateral)
        ;; Transfer collateral to liquidator
        (try! (as-contract (stx-transfer? collateral (as-contract tx-sender) tx-sender)))
        ;; Clear vault
        (map-delete vaults vault-owner)
        (ok true)
    ))
)

;; Oracle Functions
(define-public (update-price (new-price uint))
    (begin
        (asserts! (is-authorized-oracle tx-sender) err-owner-only)
        (var-set last-price new-price)
        (var-set price-valid true)
        (ok true)
    )
)

;; Governance Functions
(define-public (set-minimum-collateral-ratio (new-ratio uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set minimum-collateral-ratio new-ratio)
        (ok true)
    )
)

(define-public (set-liquidation-ratio (new-ratio uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set liquidation-ratio new-ratio)
        (ok true)
    )
)

(define-public (set-stability-fee (new-fee uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set stability-fee new-fee)
        (ok true)
    )
)

(define-public (add-liquidator (liquidator principal))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (map-set liquidators liquidator true)
        (ok true)
    )
)

(define-public (remove-liquidator (liquidator principal))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (map-delete liquidators liquidator)
        (ok true)
    )
)

(define-public (add-oracle (oracle principal))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (map-set price-oracles oracle true)
        (ok true)
    )
)

(define-public (remove-oracle (oracle principal))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (map-delete price-oracles oracle)
        (ok true)
    )
)

;; Emergency Functions
(define-public (trigger-emergency-shutdown)
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set emergency-shutdown true)
        (ok true)
    )
)

;; Read-Only Functions
(define-read-only (get-vault (owner principal))
    (map-get? vaults owner)
)

(define-read-only (get-collateral-ratio (owner principal))
    (let (
        (vault (unwrap! (map-get? vaults owner) err-low-balance))
        (collateral (get collateral vault))
        (debt (get debt vault))
    )
    (if (is-eq debt u0)
        (ok u0)
        (ok (/ (* collateral (var-get last-price)) debt))
    ))
)

(define-read-only (is-authorized-liquidator (address principal))
    (default-to false (map-get? liquidators address))
)

(define-read-only (is-authorized-oracle (address principal))
    (default-to false (map-get? price-oracles address))
)

(define-read-only (get-stability-parameters)
    {
        minimum-collateral-ratio: (var-get minimum-collateral-ratio),
        liquidation-ratio: (var-get liquidation-ratio),
        stability-fee: (var-get stability-fee),
        price: (var-get last-price),
        price-valid: (var-get price-valid),
        emergency-shutdown: (var-get emergency-shutdown)
    }
)