/**
 * VCI Offline Queue -> ProcureNet Wallet Sync Bridge
 *
 * Bridges successful VCI offline evaluation sync events into wallet settlement
 * requests so field work can be paid on confirmation.
 */

export interface VCISyncRecord {
  localId: number;
  assignmentId: string;
  evaluatorId: string;
  status: 'pending' | 'synced' | 'failed';
  scores: Record<string, { score: number; notes?: string }>;
  gpsSnapshot?: {
    lat: number;
    lng: number;
    accuracy: number;
    timestamp: string;
  };
  offlineSubmittedAt: string;
  metadata?: Record<string, unknown>;
}

export interface QueueLike {
  getRecord(localId: number): Promise<VCISyncRecord | null>;
  updateRecordMetadata(localId: number, patch: Record<string, unknown>): Promise<void>;
  markFailed(localId: number, reason: string): Promise<void>;
}

export interface USDCPaymentRequest {
  payment_id: string;
  deposit_address: string;
  qr_code?: string;
  expires_at?: string;
}

export interface PaymentWatchResult {
  confirmed: boolean;
  transaction_hash?: string;
}

export class ProcureNetWalletClient {
  constructor(
    private readonly baseUrl: string,
    private readonly apiKey: string,
    public readonly config: { autoWatch: boolean } = { autoWatch: true },
  ) {}

  async createUSDCPayment(params: {
    tenant_id: string;
    amount_usdc: number;
    network: 'base' | 'arbitrum' | 'polygon' | 'ethereum';
    token: 'USDC';
    memo: string;
    metadata: Record<string, unknown>;
  }): Promise<USDCPaymentRequest> {
    const res = await fetch(`${this.baseUrl}/mods/procurement_wallet/usdc/request`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-perplexity-mod-key': this.apiKey,
      },
      body: JSON.stringify(params),
    });

    if (!res.ok) {
      throw new Error(`Wallet API error (request): ${res.status}`);
    }

    return res.json();
  }

  async watchPayment(paymentId: string): Promise<PaymentWatchResult> {
    const res = await fetch(`${this.baseUrl}/mods/procurement_wallet/usdc/watch/${paymentId}`, {
      method: 'GET',
      headers: {
        'x-perplexity-mod-key': this.apiKey,
      },
    });

    if (!res.ok) {
      throw new Error(`Wallet API error (watch): ${res.status}`);
    }

    return res.json();
  }

  async manualConfirm(paymentId: string, adminKey: string): Promise<PaymentWatchResult> {
    const res = await fetch(`${this.baseUrl}/mods/procurement_wallet/usdc/manual-confirm`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-perplexity-mod-key': this.apiKey,
        'x-admin-key': adminKey,
      },
      body: JSON.stringify({ payment_id: paymentId }),
    });

    if (!res.ok) {
      throw new Error(`Wallet API error (manual-confirm): ${res.status}`);
    }

    return res.json();
  }
}

export class VCIProcureNetBridge {
  constructor(
    private readonly queue: QueueLike,
    private readonly wallet: ProcureNetWalletClient,
    private readonly tenantIdResolver: () => string = () => 'default-tenant',
  ) {
    this.setupWalletIntegration();
  }

  private setupWalletIntegration(): void {
    window.addEventListener('vci-sync-status', async (event: Event) => {
      const custom = event as CustomEvent<{ type: string; localId?: number }>;
      if (custom.detail?.type === 'success' && typeof custom.detail.localId === 'number') {
        await this.processWalletSettlement(custom.detail.localId);
      }
    });
  }

  async processWalletSettlement(localId: number): Promise<void> {
    try {
      const record = await this.queue.getRecord(localId);
      if (!record || record.status !== 'synced') {
        return;
      }

      const existingPaymentId = this.getMetadataString(record, 'procurenet_payment_id');
      if (existingPaymentId) {
        return;
      }

      const amount = this.calculateEvaluationValue(record);
      if (amount <= 0) {
        return;
      }

      const payment = await this.wallet.createUSDCPayment({
        tenant_id: this.tenantIdResolver(),
        amount_usdc: amount,
        network: 'base',
        token: 'USDC',
        memo: `VCI Eval: ${record.assignmentId} | Score: ${this.avgScore(record.scores).toFixed(2)}`,
        metadata: {
          vci_local_id: localId,
          assignment_id: record.assignmentId,
          evaluator_id: record.evaluatorId,
          gps: record.gpsSnapshot,
          submitted_at: record.offlineSubmittedAt,
        },
      });

      await this.queue.updateRecordMetadata(localId, {
        procurenet_payment_id: payment.payment_id,
        deposit_address: payment.deposit_address,
        status: 'payment_pending',
      });

      window.dispatchEvent(
        new CustomEvent('vci-wallet-sync', {
          detail: {
            evaluationId: localId,
            paymentId: payment.payment_id,
            amount,
            qrCode: payment.qr_code,
            expiresAt: payment.expires_at,
          },
        }),
      );

      if (this.wallet.config.autoWatch) {
        await this.wallet.watchPayment(payment.payment_id);
      }
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : 'Unknown settlement error';
      await this.queue.markFailed(localId, `Wallet settlement failed: ${message}`);
    }
  }

  async manualConfirmPayment(localId: number, adminKey: string): Promise<PaymentWatchResult> {
    const record = await this.queue.getRecord(localId);
    const paymentId = record?.metadata?.procurenet_payment_id as string | undefined;

    if (!paymentId) {
      throw new Error('No payment associated with this evaluation');
    }

    const result = await this.wallet.manualConfirm(paymentId, adminKey);

    if (result.confirmed) {
      await this.queue.updateRecordMetadata(localId, {
        status: 'payment_confirmed',
        tx_hash: result.transaction_hash,
      });
    }

    return result;
  }

  private getMetadataString(record: VCISyncRecord, key: string): string | undefined {
    const value = record.metadata?.[key];
    return typeof value === 'string' && value.trim().length > 0 ? value : undefined;
  }

  private calculateEvaluationValue(record: VCISyncRecord): number {
    const scores = Object.values(record.scores);
    if (!scores.length) {
      return 0;
    }

    const avg = scores.reduce((sum, entry) => sum + entry.score, 0) / scores.length;

    if (avg >= 9) return 500;
    if (avg >= 7) return 250;
    if (avg >= 5) return 100;
    return 0;
  }

  private avgScore(scores: Record<string, { score: number }>): number {
    const values = Object.values(scores);
    if (!values.length) {
      return 0;
    }
    return values.reduce((sum, score) => sum + score.score, 0) / values.length;
  }
}
