from dataclasses import dataclass
import hashlib
import secrets
import time
import jwt
from .schema import APIError, require

def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()

@dataclass(frozen=True)
class Principal:
    id: str
    role: str

class OIDCVerifier:
    """Issuer/audience/JWKS are operator config, never taken from unverified token URLs or claims."""
    def __init__(self, issuer, audience, jwks_url, key_client=None):
        require(isinstance(issuer,str) and issuer.startswith('https://') and isinstance(audience,str) and bool(audience),500,'identityConfigurationInvalid')
        require(isinstance(jwks_url,str) and jwks_url.startswith('https://'),500,'identityConfigurationInvalid')
        self.issuer, self.audience = issuer, audience
        self.keys = key_client or jwt.PyJWKClient(jwks_url, timeout=5, cache_jwk_set=True, lifespan=300)
    def verify(self, identity_token, nonce):
        require(isinstance(identity_token,str) and len(identity_token)<=16384,401,'invalidIdentity')
        try:
            key = self.keys.get_signing_key_from_jwt(identity_token).key
            claims = jwt.decode(identity_token, key, algorithms=['RS256'], issuer=self.issuer, audience=self.audience,
                                options={'require':['exp','iat','iss','aud','sub','nonce']}, leeway=0)
            require(isinstance(claims['sub'],str) and 0<len(claims['sub'])<=256 and claims['nonce']==nonce,401,'invalidIdentity')
            if isinstance(claims['aud'],list) and len(claims['aud'])>1:
                require(claims.get('azp')==self.audience,401,'invalidIdentity')
            require(type(claims['iat']) in (int,float) and type(claims['exp']) in (int,float)
                    and claims['exp']>claims['iat'] and claims['exp']-claims['iat']<=86400,401,'invalidIdentity')
            return self.issuer, claims['sub']
        except APIError:
            raise
        except Exception:
            raise APIError(401,'invalidIdentity') from None

class UnconfiguredIdentity:
    def verify(self, identity_token, nonce):
        raise APIError(503,'identityProviderNotConfigured')

class IdentityService:
    def __init__(self, database, verifier, clock=time.time):
        self.database, self.verifier, self.clock = database, verifier, clock
    def challenge(self):
        nonce, now = secrets.token_urlsafe(32), self.clock()
        with self.database.transaction() as db:
            db.execute('DELETE FROM challenges WHERE expires_at<=?',(now,))
            db.execute('INSERT INTO challenges VALUES(?,?)',(digest(nonce),now+300))
        return {'nonce':nonce,'expiresAt':now+300}
    def exchange(self, identity_token, nonce):
        require(isinstance(nonce,str) and 32<=len(nonce)<=128,401,'invalidChallenge')
        issuer, subject = self.verifier.verify(identity_token,nonce)
        now, credential = self.clock(), secrets.token_urlsafe(32)
        with self.database.transaction() as db:
            challenge = db.execute('DELETE FROM challenges WHERE nonce_hash=? AND expires_at>? RETURNING nonce_hash',(digest(nonce),now)).fetchone()
            require(challenge is not None,401,'invalidChallenge')
            db.execute('INSERT OR IGNORE INTO users(id,issuer,subject) VALUES(?,?,?)',(secrets.token_hex(16),issuer,subject))
            user = db.execute('SELECT id FROM users WHERE issuer=? AND subject=?',(issuer,subject)).fetchone()
            db.execute('DELETE FROM sessions WHERE expires_at<=?',(now,))
            db.execute('INSERT INTO sessions VALUES(?,?,?)',(digest(credential),user['id'],now+86400))
        return {'accessToken':credential,'tokenType':'Bearer','expiresAt':now+86400}
    def authenticate(self, authorization):
        require(isinstance(authorization,str) and authorization.startswith('Bearer ') and len(authorization)<=256,401,'authenticationRequired')
        credential = authorization[7:]
        with self.database.connect() as db:
            row = db.execute('SELECT users.id,users.role FROM sessions JOIN users ON users.id=sessions.user_id WHERE token_hash=? AND expires_at>?',(digest(credential),self.clock())).fetchone()
        require(row is not None,401,'authenticationRequired')
        return Principal(row['id'],row['role'])
    def revoke(self, authorization):
        self.authenticate(authorization)
        with self.database.transaction() as db:
            db.execute('DELETE FROM sessions WHERE token_hash=?',(digest(authorization[7:]),))
