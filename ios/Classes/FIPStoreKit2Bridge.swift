import Foundation
import StoreKit

@objc(FIPStoreKit2Bridge)
public final class FIPStoreKit2Bridge: NSObject {
    private static let productsTimeoutSeconds: UInt64 = 20

    @available(iOS 15.0, *)
    private static var pendingTransactions: [String: Transaction] = [:]

    @objc(fetchProductsWithIdentifiers:completion:)
    public static func fetchProducts(
        withIdentifiers identifiers: [String],
        completion: @escaping (NSArray?, NSError?) -> Void
    ) {
        guard #available(iOS 15.0, *) else {
            completion(nil, unavailableError())
            return
        }

        requestProducts(withIdentifiers: identifiers) { products, error in
            if let products {
                let items = products.map { productObject($0) } as NSArray
                completion(items, nil)
            } else {
                completion(nil, error)
            }
        }
    }

    @objc(purchaseProductWithIdentifier:completion:)
    public static func purchaseProduct(
        withIdentifier identifier: String,
        completion: @escaping (NSDictionary?, NSDictionary?) -> Void
    ) {
        guard #available(iOS 15.0, *) else {
            completion(nil, errorObject(
                code: "E_SERVICE_ERROR",
                message: "StoreKit 2 requires iOS 15.0 or newer.",
                debugMessage: "StoreKit 2 unavailable"
            ))
            return
        }

        requestProducts(withIdentifiers: [identifier]) { products, error in
            guard error == nil else {
                completion(nil, errorObject(
                    code: "E_SERVICE_ERROR",
                    message: error?.localizedDescription ?? "StoreKit 2 product request failed.",
                    debugMessage: String(describing: error)
                ))
                return
            }

            guard let products else {
                completion(nil, errorObject(
                    code: "E_SERVICE_ERROR",
                    message: "StoreKit 2 product request failed.",
                    debugMessage: "StoreKit 2 returned no result"
                ))
                return
            }

            Task {
                do {
                    guard let product = products.first else {
                        completion(nil, errorObject(
                            code: "E_ITEM_UNAVAILABLE",
                            message: "Invalid product ID.",
                            debugMessage: "StoreKit 2 product not found"
                        ))
                        return
                    }

                    let result = try await product.purchase()
                    switch result {
                    case .success(let verification):
                        let transaction = try checkVerified(verification)
                        let transactionId = String(transaction.id)
                        pendingTransactions[transactionId] = transaction
                        completion(transactionObject(transaction), nil)
                    case .userCancelled:
                        completion(nil, errorObject(
                            code: "E_USER_CANCELLED",
                            message: "Payment Cancelled.",
                            debugMessage: "StoreKit 2 user cancelled"
                        ))
                    case .pending:
                        completion(nil, errorObject(
                            code: "E_USER_ERROR",
                            message: "Purchase is pending approval.",
                            debugMessage: "StoreKit 2 purchase pending"
                        ))
                    @unknown default:
                        completion(nil, errorObject(
                            code: "E_UNKNOWN",
                            message: "Unknown purchase result.",
                            debugMessage: "StoreKit 2 unknown purchase result"
                        ))
                    }
                } catch {
                    completion(nil, errorObject(
                        code: "E_SERVICE_ERROR",
                        message: error.localizedDescription,
                        debugMessage: String(describing: error)
                    ))
                }
            }
        }
    }

    @objc(finishTransactionWithIdentifier:completion:)
    public static func finishTransaction(
        withIdentifier identifier: String,
        completion: @escaping (Bool) -> Void
    ) {
        guard #available(iOS 15.0, *) else {
            completion(false)
            return
        }

        Task {
            if let transaction = pendingTransactions.removeValue(forKey: identifier) {
                await transaction.finish()
                completion(true)
                return
            }

            for await result in Transaction.currentEntitlements {
                guard case .verified(let transaction) = result else { continue }
                if String(transaction.id) == identifier {
                    await transaction.finish()
                    completion(true)
                    return
                }
            }

            completion(false)
        }
    }

    @available(iOS 15.0, *)
    private static func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified(_, let error):
            throw error
        }
    }

    @available(iOS 15.0, *)
    private static func requestProducts(
        withIdentifiers identifiers: [String],
        completion: @escaping ([Product]?, NSError?) -> Void
    ) {
        let state = CompletionState()
        let productTask = Task {
            do {
                let products = try await Product.products(for: identifiers)
                if state.finish() {
                    completion(products, nil)
                }
            } catch {
                if state.finish() {
                    completion(nil, error as NSError)
                }
            }
        }

        Task {
            try? await Task.sleep(nanoseconds: productsTimeoutSeconds * 1_000_000_000)
            if state.finish() {
                productTask.cancel()
                completion(nil, timedOutError())
            }
        }
    }

    @available(iOS 15.0, *)
    private static func productObject(_ product: Product) -> [String: Any] {
        var object: [String: Any] = [
            "productId": product.id,
            "price": product.price.description,
            "currency": product.priceFormatStyle.currencyCode,
            "title": product.displayName,
            "description": product.description,
            "localizedPrice": product.displayPrice,
            "subscriptionPeriodNumberIOS": "0",
            "subscriptionPeriodUnitIOS": "",
            "introductoryPrice": "",
            "introductoryPriceNumberIOS": "",
            "introductoryPricePaymentModeIOS": "",
            "introductoryPriceNumberOfPeriodsIOS": "",
            "introductoryPriceSubscriptionPeriodIOS": "",
            "discounts": [],
            "originalPrice": product.price.description
        ]

        if let period = product.subscription?.subscriptionPeriod {
            object["subscriptionPeriodNumberIOS"] = String(period.value)
            object["subscriptionPeriodUnitIOS"] = periodUnit(period.unit)
        }

        if let offer = product.subscription?.introductoryOffer {
            object["introductoryPrice"] = offer.displayPrice
            object["introductoryPriceNumberIOS"] = offer.price.description
            object["introductoryPricePaymentModeIOS"] = paymentMode(offer.paymentMode)
            object["introductoryPriceNumberOfPeriodsIOS"] = String(offer.periodCount)
            object["introductoryPriceSubscriptionPeriodIOS"] = periodUnit(offer.period.unit)
        }

        if let offers = product.subscription?.promotionalOffers {
            object["discounts"] = offers.map { discountObject($0) }
        }

        return object
    }

    @available(iOS 15.0, *)
    private static func transactionObject(_ transaction: Transaction) -> NSDictionary {
        var object: [String: Any] = [
            "transactionDate": milliseconds(transaction.purchaseDate),
            "transactionId": String(transaction.id),
            "productId": transaction.productID,
            "transactionStateIOS": 1
        ]

        object["originalTransactionDateIOS"] = milliseconds(transaction.originalPurchaseDate)
        object["originalTransactionIdentifierIOS"] = String(transaction.originalID)

        return object as NSDictionary
    }

    @available(iOS 15.0, *)
    private static func discountObject(_ offer: Product.SubscriptionOffer) -> [String: Any] {
        [
            "identifier": offer.id ?? "",
            "type": "SUBSCRIPTION",
            "numberOfPeriods": String(offer.periodCount),
            "price": offer.price.description,
            "localizedPrice": offer.displayPrice,
            "paymentMode": paymentMode(offer.paymentMode),
            "subscriptionPeriod": periodUnit(offer.period.unit)
        ]
    }

    @available(iOS 15.0, *)
    private static func periodUnit(_ unit: Product.SubscriptionPeriod.Unit) -> String {
        switch unit {
        case .day:
            return "DAY"
        case .week:
            return "WEEK"
        case .month:
            return "MONTH"
        case .year:
            return "YEAR"
        @unknown default:
            return ""
        }
    }

    @available(iOS 15.0, *)
    private static func paymentMode(_ mode: Product.SubscriptionOffer.PaymentMode) -> String {
        switch mode {
        case .freeTrial:
            return "FREETRIAL"
        case .payAsYouGo:
            return "PAYASYOUGO"
        case .payUpFront:
            return "PAYUPFRONT"
        default:
            return ""
        }
    }

    private static func milliseconds(_ date: Date) -> NSNumber {
        NSNumber(value: date.timeIntervalSince1970 * 1000)
    }

    private static func unavailableError() -> NSError {
        NSError(
            domain: "FIPStoreKit2Bridge",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "StoreKit 2 requires iOS 15.0 or newer."]
        )
    }

    private static func timedOutError() -> NSError {
        NSError(
            domain: "FIPStoreKit2Bridge",
            code: -1001,
            userInfo: [NSLocalizedDescriptionKey: "StoreKit 2 product request timed out."]
        )
    }

    private static func errorObject(
        code: String,
        message: String,
        debugMessage: String
    ) -> NSDictionary {
        [
            "code": code,
            "message": message,
            "debugMessage": debugMessage
        ] as NSDictionary
    }
}

private final class CompletionState {
    private let lock = NSLock()
    private var completed = false

    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if completed {
            return false
        }

        completed = true
        return true
    }
}
