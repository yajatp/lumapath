from dataclasses import dataclass
import math
import re

CATEGORIES = frozenset(('poorLighting','sidewalkObstruction','unevenSurface','damagedCurb','stairsIssue','narrowPassage','entranceBarrier','otherAccessibilityConcern'))
STATES = frozenset(('pendingReview','publishedUnverified','verified','rejected','needsInformation','disputed','resolved','reopened','expired','withdrawn'))
TOKEN = re.compile(r'[A-Za-z0-9_.:-]{1,128}\Z')

class APIError(Exception):
    def __init__(self, status, code):
        self.status, self.code = status, code
        super().__init__(code)

def require(condition, status=400, code='invalidPayload'):
    if not condition:
        raise APIError(status, code)

def token(value):
    require(isinstance(value, str) and TOKEN.fullmatch(value) is not None)
    return value

def number(value, minimum, maximum):
    require(type(value) in (int,float) and math.isfinite(value) and minimum <= value <= maximum)
    return value

def text(value, limit=1000):
    require(isinstance(value,str) and 1 <= len(value.strip()) <= limit and not any(ord(c)<32 and c not in '\n\t' for c in value))
    return value.strip()

def exact(payload, required, optional=()):
    require(isinstance(payload,dict) and set(required) <= set(payload) <= set(required)|set(optional))

@dataclass(frozen=True)
class ReportInput:
    category: str
    description: str
    segmentID: str
    side: str
    level: str
    latitude: float
    longitude: float
    observedAt: float
    expectedPersistence: str
    sourceMode: str
    publicLocationConfirmed: bool
    restrictionSchedule: dict | None = None

    @classmethod
    def parse(cls, body, now):
        fields = tuple(cls.__dataclass_fields__)
        exact(body, tuple(k for k in fields if k!='restrictionSchedule'), ('restrictionSchedule',))
        require(isinstance(body['category'],str) and body['category'] in CATEGORIES)
        require(body['publicLocationConfirmed'] is True)
        require(isinstance(body['expectedPersistence'],str) and body['expectedPersistence'] in ('temporary','structural','lighting','scheduled'))
        require(isinstance(body['sourceMode'],str) and body['sourceMode'] in ('manualPublicLocation','reviewedPublicSensorDraft'))
        schedule=body.get('restrictionSchedule')
        if body['expectedPersistence']=='scheduled':
            require(body['category']=='entranceBarrier' and isinstance(schedule,dict))
            exact(schedule,('startsAt','endsAt','applicableUTCHours'))
            starts=number(schedule['startsAt'],0,now+7*86400); ends=number(schedule['endsAt'],starts,body['observedAt']+7*86400)
            require(ends>starts and isinstance(schedule['applicableUTCHours'],list) and 1<=len(schedule['applicableUTCHours'])<=24
                    and all(type(hour) is int and 0<=hour<=23 for hour in schedule['applicableUTCHours']))
        else: require(schedule is None)
        text(body['description'])
        for key in ('segmentID','side','level'): token(body[key])
        number(body['latitude'],-90,90); number(body['longitude'],-180,180)
        number(body['observedAt'], max(0,now-365*86400),now)
        return cls(**body)

def revision(value):
    require(type(value) is int and value > 0)
    return value
