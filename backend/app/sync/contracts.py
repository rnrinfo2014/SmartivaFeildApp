from typing import Annotated, Literal
from uuid import UUID
from pydantic import BaseModel, ConfigDict, Field

EntityType = Literal['sites','site_contacts','floors','floors_and_zones','assets',
                     'network_interfaces','cameras','asset_connections','observations','voice_notes']
class Mutation(BaseModel):
    model_config = ConfigDict(extra='forbid')
    operation_id: UUID
    site_id: UUID
    entity_type: EntityType
    entity_id: UUID
    operation: Literal['create','update','delete']
    base_version: Annotated[int, Field(strict=True, ge=0)]
    payload: dict = Field(default_factory=dict)
