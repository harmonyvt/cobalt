import type { CobaltPickerResponse, CobaltSaveRequestBody } from '@imput/cobalt-client';

type PendingPicker = {
  response: CobaltPickerResponse;
  request: CobaltSaveRequestBody;
};

let pendingPicker: PendingPicker | undefined;

export function setPendingPicker(value: PendingPicker | undefined) {
  pendingPicker = value;
}

export function getPendingPicker() {
  return pendingPicker;
}
