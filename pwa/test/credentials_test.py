import base64
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('credentials', Path(__file__).parents[1] / 'scripts/prepare-credentials.py')
loader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(loader)

class CredentialFormats(unittest.TestCase):
    def test_raw_and_encoded_json(self):
        data = {'type': 'service_account', 'client_email': 'test@example.invalid', 'private_key': 'synthetic-key', 'token_uri': 'https://oauth2.googleapis.com/token'}
        raw = json.dumps(data)
        for value in [raw, '\ufeff' + raw, base64.b64encode(raw.encode()).decode() + '\n']:
            self.assertEqual(json.loads(loader.normalize(value)), data)

    def test_invalid_value_is_rejected_without_echoing_it(self):
        for value in ['sensitive-invalid-value', '{}', '"quoted-key"']:
            with self.assertRaises(ValueError) as caught:
                loader.normalize(value)
            self.assertNotIn(value, str(caught.exception))
