import Foundation
import RxSwift
import HSHDWalletKit

class SpvBlockchain {
    weak var delegate: IBlockchainDelegate?

    private let peerGroup: IPeerGroup
    private let storage: ISpvStorage
    private let network: INetwork
    private let transactionSigner: TransactionSigner

    let ethereumAddress: String

    let gasLimitEthereum = 21_000
    let gasLimitErc20 = 100_000

    private init(peerGroup: IPeerGroup, storage: ISpvStorage, network: INetwork, transactionSigner: TransactionSigner, ethereumAddress: String) {
        self.peerGroup = peerGroup
        self.storage = storage
        self.network = network
        self.transactionSigner = transactionSigner
        self.ethereumAddress = ethereumAddress
    }

    private func send(to address: String, amount: String, gasPrice: Int) throws -> EthereumTransaction {
        guard let accountState = storage.accountState else {
            throw SendError.noAccountState
        }

        let nonce = accountState.nonce

        let rawTransaction = RawTransaction(
                wei: amount,
                to: address,
                gasPrice: gasPrice,
                gasLimit: gasLimitEthereum,
                nonce: nonce
        )

        let signature = try transactionSigner.sign(rawTransaction: rawTransaction)

        let transactionHash = transactionSigner.hash(rawTransaction: rawTransaction, signature: signature)

        let transaction = EthereumTransaction(
                hash: transactionHash.toHexString(),
                nonce: nonce,
                from: ethereumAddress,
                to: address,
                amount: amount,
                gasLimit: gasLimitEthereum,
                gasPriceInWei: gasPrice
        )

        storage.save(transactions: [transaction])

        peerGroup.send(rawTransaction: rawTransaction, signature: signature)

        return transaction
    }

}

extension SpvBlockchain: IBlockchain {

    func start() {
        peerGroup.start()
    }

    func clear() {
        storage.clear()
    }

    func gasPriceInWei(priority: FeePriority) -> Int {
        return GasPrice.defaultGasPrice.mediumPriority
    }

    var lastBlockHeight: Int? {
        return storage.lastBlockHeader?.height
    }

    func balance(forAddress address: String) -> String? {
        return storage.accountState?.balance.asString(withBase: 10)
    }

    func transactionsSingle(fromHash: String?, limit: Int?, contractAddress: String?) -> Single<[EthereumTransaction]> {
        return storage.transactionsSingle(fromHash: fromHash, limit: limit, contractAddress: contractAddress)
    }

    var syncState: EthereumKit.SyncState {
        return peerGroup.syncState
    }

    func syncState(contractAddress: String) -> EthereumKit.SyncState {
        return EthereumKit.SyncState.synced
    }

    func register(contractAddress: String) {
    }

    func unregister(contractAddress: String) {
    }

    func sendSingle(to address: String, amount: String, priority: FeePriority) -> Single<EthereumTransaction> {
        return Single.create { [unowned self] observer in
            do {
                let transaction = try self.send(to: address, amount: amount, gasPrice: GasPrice.defaultGasPrice.mediumPriority)
                observer(.success(transaction))
            } catch {
                observer(.error(error))
            }

            return Disposables.create()
        }
    }

    func sendErc20Single(to address: String, contractAddress: String, amount: String, priority: FeePriority) -> Single<EthereumTransaction> {
        let stubTransaction = EthereumTransaction(hash: "", nonce: 0, from: "", to: "", amount: "", gasLimit: 0, gasPriceInWei: 0)
        return Single.just(stubTransaction)
    }
}

extension SpvBlockchain: IPeerGroupDelegate {

    func onUpdate(syncState: EthereumKit.SyncState) {
        delegate?.onUpdate(syncState: syncState)
    }

    func onUpdate(accountState: AccountState) {
        storage.save(accountState: accountState)

        delegate?.onUpdate(balance: accountState.balance.asString(withBase: 10))
    }

}

extension SpvBlockchain {

    enum SendError: Error {
        case noAccountState
    }

}

extension SpvBlockchain {

    static func spvBlockchain(storage: ISpvStorage, words: [String], testMode: Bool, logger: Logger? = nil) -> SpvBlockchain {
        let network = Ropsten()

        let hdWallet = HDWallet(seed: Mnemonic.seed(mnemonic: words), coinType: network.coinType, xPrivKey: network.privateKeyPrefix.bigEndian, xPubKey: network.publicKeyPrefix.bigEndian)

        let privateKey = try! hdWallet.privateKey(account: 0, index: 0, chain: .external)
        let publicKey = privateKey.publicKey(compressed: false).raw
        let address = EIP55.encode(CryptoUtils.shared.sha3(publicKey.dropFirst()).suffix(20))
        let addressData = Data(hex: String(address[address.index(address.startIndex, offsetBy: 2)...]))

        let connectionPrivateKey = try! hdWallet.privateKey(account: 100, index: 100, chain: .external)
        let connectionPublicKey = Data(connectionPrivateKey.publicKey(compressed: false).raw.suffix(from: 1))
        let connectionECKey = ECKey(
                privateKey: connectionPrivateKey.raw,
                publicKeyPoint: ECPoint(nodeId: connectionPublicKey)
        )

        let peerProvider = PeerProvider(network: network, storage: storage, connectionKey: connectionECKey, logger: logger)
        let validator = BlockValidator()
        let blockHelper = BlockHelper(storage: storage, network: network)
        let peerGroup = PeerGroup(storage: storage, peerProvider: peerProvider, validator: validator, blockHelper: blockHelper, address: addressData, logger: logger)
        let transactionSigner = TransactionSigner(network: network, rawPrivateKey: privateKey.raw)

        let spvBlockchain = SpvBlockchain(peerGroup: peerGroup, storage: storage, network: network, transactionSigner: transactionSigner, ethereumAddress: address)

        peerGroup.delegate = spvBlockchain

        return spvBlockchain
    }

}
