from pathlib import Path
from typing import Protocol
import io
import os
import secrets
from PIL import Image, UnidentifiedImageError
from .schema import APIError, require

class ObjectStorage(Protocol):
    def put(self, data: bytes) -> str: ...
    def read(self, key: str) -> bytes: ...
    def delete(self, key: str) -> None: ...

class LocalObjectStorage:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True,exist_ok=True,mode=0o700)
        os.chmod(self.root,0o700)
    def path(self,key):
        require(isinstance(key,str) and len(key)==64 and all(c in '0123456789abcdef' for c in key),500,'invalidObjectKey')
        path = self.root/key
        require(not path.is_symlink(),500,'invalidObjectType')
        return path
    def put(self,data):
        key = secrets.token_hex(32)
        with self.path(key).open('xb') as file:
            os.chmod(file.name,0o600); file.write(data); file.flush(); os.fsync(file.fileno())
        return key
    def reconcile(self, referenced, older_than):
        for path in self.root.iterdir():
            if len(path.name)==64 and all(c in '0123456789abcdef' for c in path.name) and not path.is_symlink():
                if path.name not in referenced and path.stat().st_mtime<older_than:
                    path.unlink()
    def read(self,key):
        return self.path(key).read_bytes()
    def delete(self,key):
        self.path(key).unlink(missing_ok=True)

def validate_image(data, media_type):
    require(isinstance(data,bytes) and 0<len(data)<=1_048_576,413,'evidenceBudget')
    require(isinstance(media_type,str) and media_type in ('image/png','image/jpeg'))
    try:
        with Image.open(io.BytesIO(data)) as image:
            require(image.format == ('PNG' if media_type=='image/png' else 'JPEG'))
            require(image.width>0 and image.height>0 and image.width*image.height<=4_000_000)
            # Review must happen after client-side metadata removal. Reject rather than rewrite reviewed bytes.
            require(not image.getexif() and not any(k not in ('jfif','jfif_version','jfif_unit','jfif_density') for k in image.info),400,'evidenceMetadataMustBeRemoved')
        with Image.open(io.BytesIO(data)) as image:
            image.verify()
    except APIError:
        raise
    except Exception:
        raise APIError(400,'invalidEvidenceImage') from None
