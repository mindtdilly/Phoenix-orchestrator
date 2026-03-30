export interface WCSInput {
  customerId?: string | null;
  email?: string | null;
  phone?: string | null;
  deviceId?: string | null;
}

export type WCSMode = 'resolved' | 'partial' | 'anonymous';
export type WTransport = 'sse' | 'websocket';

export interface WCSResult {
  score: number;
  mode: WCSMode;
  transport: WTransport;
  factors: {
    customerId: number;
    email: number;
    phone: number;
    deviceId: number;
  };
}

const WEIGHTS = {
  customerId: 100,
  email: 40,
  phone: 40,
  deviceId: 20,
} as const;

function present(value?: string | null): boolean {
  return Boolean(value && value.trim().length > 0);
}

export class WCSEngine {
  static calculate(input: WCSInput): WCSResult {
    const factors = {
      customerId: present(input.customerId) ? WEIGHTS.customerId : 0,
      email: present(input.email) ? WEIGHTS.email : 0,
      phone: present(input.phone) ? WEIGHTS.phone : 0,
      deviceId: present(input.deviceId) ? WEIGHTS.deviceId : 0,
    };

    const score = factors.customerId + factors.email + factors.phone + factors.deviceId;

    if (score >= 100) {
      return { score, mode: 'resolved', transport: 'sse', factors };
    }

    if (score >= 40) {
      return { score, mode: 'partial', transport: 'websocket', factors };
    }

    return { score, mode: 'anonymous', transport: 'websocket', factors };
  }
}
