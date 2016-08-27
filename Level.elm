module Level exposing (Level, init, fromRooms, finalize, turnCreature, moveCreatures, injureCreature, purge, collectCoin, isBlocked, isCoin, isCrystal, isEntrance, creatureAt, entitiesAt, playerSees, liberateCrystal)

import Point exposing (Point)
import Direction exposing (Direction(..))
import Room exposing (Room)
import Graph exposing (Graph)

import Util
import Path
import Configuration

import Warrior
import Creature
import Event exposing (Event)
import Entity exposing (Entity)

-- TYPE

type alias Level = { walls : List Point
                   , floors : List Point
                   , doors : List Point
                   , coins : List Point
                   , creatures : List Creature.Model
                   , viewed : List Point
                   , downstairs : Maybe Point
                   , upstairs : Maybe Point
                   , crystal : Maybe (Point, Bool)
                   , entrance : Maybe (Point, Bool)
                   }

-- INIT

init : Level
init =
  { walls = []
  , floors = []
  , doors = []
  , creatures = []
  , coins = []
  , upstairs = Nothing --origin
  , downstairs = Nothing --origin
  , crystal = Nothing
  , entrance = Nothing

  , viewed = []
  }

-- should probably spawn creatures here too
-- since we finally know what level we are!
finalize : Int -> Level -> Level
finalize depth model =
  model
  |> finalizeEntrance depth
  |> finalizeCrystal depth

finalizeEntrance depth model =
  if depth == 0 then
    case model.upstairs of
      Nothing -> model
      Just pt ->
        model
        |> emplaceEntrance pt
  else
    model

finalizeCrystal depth model =
  if depth == (Configuration.levelCount - 1) then
    case model.downstairs of
      Nothing -> model
      Just pt ->
        model
        |> emplaceCrystal pt
  else
    model

origin = {x=0,y=0}

-- QUERY

isWall : Point -> Level -> Bool
isWall pt model =
  List.any (\pos -> pos == pt) model.walls

isCoin : Point -> Level -> Bool
isCoin pt model =
  List.any (\pos -> pos == pt) model.coins

isCreature : Point -> Level -> Bool
isCreature pt model =
  List.any (\pos -> pos == pt) (List.map .position model.creatures)

isDoor : Point -> Level -> Bool
isDoor pt model =
  List.any (\p -> p == pt) model.doors

isFloor : Point -> Level -> Bool
isFloor position model =
  List.any (\p -> p == position) model.floors

isStairsUp : Point -> Level -> Bool
isStairsUp position model =
  case model.upstairs of
    Just pt ->
      position == pt
    Nothing ->
      False

isStairsDown : Point -> Level -> Bool
isStairsDown position model =
  case model.downstairs of
    Just pt ->
      position == pt
    Nothing ->
      False
  --model.downstairs == position

isEntrance : Point -> Level -> Bool
isEntrance position model =
  case model.entrance of
    Just (pt,_) ->
      position == pt
    Nothing ->
      False

isCrystal : Point -> Level -> Bool
isCrystal position model =
  case model.crystal of
    Just (pt,_) ->
      position == pt
    Nothing ->
      False

hasBeenViewed : Point -> Level -> Bool
hasBeenViewed point model =
  List.member point model.viewed

isBlocked : Point -> Level -> Bool
isBlocked position model =
  isWall position model ||
  isCreature position model
  --isDoor position model

isAlive livingThing =
  livingThing.hp > 0

entitiesAt : Point -> Level -> List Entity
entitiesAt point model =
  let
    monster =
      let creature = model |> creatureAt point in
      case creature of
        Just creature' ->
          Just (Entity.monster creature')
        Nothing ->
          Nothing

    door =
      if isDoor point model then
        Just (Entity.door point)
      else
        Nothing

    wall =
      if isWall point model then
        Just (Entity.wall point)
      else
        Nothing

    floor =
      if isFloor point model then
        Just (Entity.floor point)
      else
        Nothing

    coin =
      if isCoin point model then
        Just (Entity.coin point)
      else
        Nothing

    downstairs =
      if isStairsDown point model then
        Just (Entity.downstairs point)
      else
        Nothing

    upstairs =
      if isStairsUp point model then
        Just (Entity.upstairs point)
      else
        Nothing

    entrance =
      if isEntrance point model then
        case model.entrance of
          Nothing ->
            Nothing
          Just (pt,open) ->
            Just (Entity.entrance open point)
      else
        Nothing

    crystal =
      if isCrystal point model then
        case model.crystal of
          Nothing -> 
            Nothing
          Just (pt,taken) ->
            Just (Entity.crystal taken point)
      else
        Nothing

    entities =
      [ floor
      , door
      , wall
      , coin
      , monster
      , downstairs
      , upstairs
      , entrance
      , crystal
      ]
  in
    entities
    |> List.filterMap identity

creatureAt : Point -> Level -> Maybe Creature.Model
creatureAt pt model =
  let
    creatures' =
      List.filter (\c -> c.position == pt) model.creatures
  in
    List.head creatures'

-- HELPERS (for update)

playerSees : Point -> Level -> Level
playerSees pt model =
  if List.member pt model.viewed then
    model
  else
    { model | viewed = pt :: model.viewed }

turnCreature : Creature.Model -> Direction -> Level -> Level
turnCreature creature direction model =
  let
    creatures' =
      model.creatures
      |> List.map (\c -> if c == creature then c |> Creature.turn direction else c)
  in
    { model | creatures = creatures' }

moveCreatures : Warrior.Model -> Level -> (Level, List Event, Warrior.Model)
moveCreatures player model =
  model.creatures
  |> List.foldl creatureSteps (model, [], player)

creatureSteps : Creature.Model -> (Level, List Event, Warrior.Model) -> (Level, List Event, Warrior.Model)
creatureSteps creature (model, events, player) =
  (model, events, player)
  |> creatureMoves creature
  |> creatureAttacks creature

creatureMoves : Creature.Model -> (Level, List Event, Warrior.Model) -> (Level, List Event, Warrior.Model)
creatureMoves creature (model, events, player) =
  if canCreatureStep creature player model then
    let
      creature' =
        Creature.step creature

      creatures' =
        model.creatures
        |> List.map (\c -> if c.id == creature.id then creature' else c)
    in
      Debug.log ("Creature moves: " ++ (Creature.describe creature) ++ "(" ++ (toString creature.id) ++ ")")
      ({ model | creatures = creatures' }
      , events
      , player
      )
   else
     (model, events, player)

creatureAttacks : Creature.Model -> (Level, List Event, Warrior.Model) -> (Level, List Event, Warrior.Model)
creatureAttacks creature (model, events, player) =
  let
    pos =
      creature.position
      |> Point.slide creature.direction

    dmg =
      creature.attack - player.defense
  in
    if pos == player.position then
       (model, events, player)
       |> playerTakesDamage creature dmg
       |> playerDies
    else
      (model, events, player)

playerTakesDamage creature amount (model, events, player) =
  let
    player' =
      (Warrior.takeDamage amount player)

    event =
      Event.defend creature amount
  in
    (model, event :: events, player')

playerDies (model, events, player) =
  if not (isAlive player) then
    let event = Event.death in
    (model, event :: events, player)
  else
    (model, events, player)

canCreatureStep creature player model =
  let
    next =
      creature.position
      |> Point.slide creature.direction

    isPlayer =
      player.position == next

    blocked =
      (isBlocked next model)
  in
    not (isPlayer || blocked)

injureCreature : Creature.Model -> Int -> Level -> Level
injureCreature creature amount model =
  let
    creatures' =
      model.creatures
      |> List.map (\c ->
        if c == creature then
           c
           |> Creature.injure amount
           |> Creature.engage
        else c)
  in
    { model | creatures = creatures' }

purge : Level -> (Level, List Event)
purge model =
  let
    survivors =
      List.filter isAlive model.creatures

    killed =
      List.filter (not << isAlive) model.creatures

    deathEvents =
      List.map Event.killEnemy killed
  in
    ({ model | creatures = survivors }, deathEvents)


collectCoin : Point -> Level -> Level
collectCoin pt model =
  let
    coins' =
      model.coins
      |> List.filter (not << (\c -> c == pt))
  in
    { model | coins = coins' }

liberateCrystal : Level -> Level
liberateCrystal model =
  { model | crystal = case model.crystal of
      Nothing -> Nothing
      Just (pt,taken) ->
        Just (pt, True)
    }

-- GENERATE

-- actually build out the rooms and corridors for a level
fromRooms : List Room -> Level
fromRooms roomCandidates =
  let
    rooms =
      roomCandidates
      |> Room.filterOverlaps
  in
    init -- depth
    |> extrudeRooms rooms
    |> connectRooms rooms
    |> spawnCreatures rooms
    |> extrudeStairwells --depth
    |> dropCoins

extrudeRooms : List Room -> Level -> Level
extrudeRooms rooms model =
  rooms
  |> List.foldr extrudeRoom model

extrudeRoom : Room -> Level -> Level
extrudeRoom room model =
  let
      (walls,floors) =
        Room.layout room
  in
     { model | walls  = model.walls ++ walls
             , floors = model.floors ++ floors }

connectRooms : List Room -> Level -> Level
connectRooms rooms model =
  let
    maybeNetwork =
      Room.network rooms

    model' =
      model

  in
    case maybeNetwork of
      Just graph ->
        graph
        |> Graph.fold connectRooms' model

      Nothing ->
        model

connectRooms' : (Room,Room) -> Level -> Level
connectRooms' (a, b) model =
  let
    direction =
      Direction.invert (Room.directionBetween a b)

    xOverlapStart =
      (max a.origin.x b.origin.x) + 1

    xOverlapEnd =
      (min (a.origin.x+a.width) (b.origin.x+b.width)) - 1

    xOverlapRange =
      [(xOverlapStart)..(xOverlapEnd)]

    sampleOverlap = \overlap ->
      --overlap |> List.head |> Maybe.withDefault -1
      --overlap |> List.head |> Maybe.withDefault (Debug.crash)
       Util.getAt overlap ((a.height ^ 31 + b.origin.x) % (max 1 (List.length overlap - 1)))
       |> Maybe.withDefault -1

    yOverlapStart =
      (max a.origin.y b.origin.y) + 1

    yOverlapEnd =
      (min (a.origin.y+a.height) (b.origin.y+b.height)) - 1

    yOverlapRange =
      [(yOverlapStart)..(yOverlapEnd)]

    startPosition =
      case direction of
        North ->
          Just {x=(sampleOverlap xOverlapRange), y=a.origin.y}

        South ->
          Just {x=(sampleOverlap xOverlapRange), y=a.origin.y+a.height}

        East ->
          Just {x=a.origin.x+a.width, y=(sampleOverlap yOverlapRange)}

        West ->
          Just {x=a.origin.x, y=(sampleOverlap yOverlapRange)}

        _ ->
          Nothing
  in
    case startPosition of
      Just pos ->
        model
        |> extrudeCorridor (round (Room.distance a b)) pos direction

      Nothing ->
        model

extrudeCorridor : Int -> Point -> Direction -> Level -> Level
extrudeCorridor depth pt dir model =
  extrudeCorridor' pt dir depth model

extrudeCorridor' pt dir depth model =
  let
    model' =
      { model | floors = pt :: model.floors  }
              |> addWallsAround pt
              |> removeWall pt

    next =
      Point.slide dir pt

    foundFloor =
      (List.any (\pt' -> pt' == pt) model.floors)
  in
    if foundFloor || depth < 0 then
      model'
      |> emplaceDoor (pt |> Point.slide (Direction.invert dir))
    else
      model'
      |> extrudeCorridor' (pt |> Point.slide dir) dir (depth-1)


-- doors
emplaceDoor : Point -> Level -> Level
emplaceDoor pt model =
  { model | doors = pt :: model.doors }
          |> removeWall pt

-- stairs

extrudeStairwells : Level -> Level
extrudeStairwells model =
  let
    adjacentToFloor = (\pt ->
        (Direction.cardinalDirections
        |> List.map (\direction -> Point.slide direction pt)
        |> List.filter (\pt' -> List.member pt' (model.floors))
        |> List.length) == 1
      )

    adjacentToTwoWalls = (\pt ->
        ([[ North, South ], [ East, West ]]
        |> List.map (\ds ->
          ds
          |> List.map (\d -> Point.slide d pt)
          |> List.filter (\pt -> (model |> isWall pt))
        )
        |> List.filter (\ls -> List.length ls > 0)
        |> List.length) == 1
      )

    candidates =
      model.walls
      |> List.filter adjacentToFloor
      |> List.filter adjacentToTwoWalls

    (up, down) =
      candidates
      |> List.map2 (,) (List.reverse candidates)
      |> List.filter (\(a,b) -> not (a.x == b.x && a.y == b.y))
      |> List.sortBy (\(a,b) -> Point.distance a b)
      |> List.reverse
      |> List.head
      |> Maybe.withDefault (origin, origin)
  in
    model
    |> emplaceUpstairs up
    |> emplaceDownstairs down

emplaceUpstairs : Point -> Level -> Level
emplaceUpstairs point model =
  { model | upstairs = Just point }
          |> addWallsAround point
          |> removeWall point

emplaceDownstairs : Point -> Level -> Level
emplaceDownstairs point model =
  { model | downstairs = Just point }
          |> addWallsAround point
          |> removeWall point

emplaceCrystal : Point -> Level -> Level
emplaceCrystal point model =
  { model | crystal = Just (point, False)
          , downstairs = Nothing
          }
          |> addWallsAround point
          |> removeWall point

emplaceEntrance : Point -> Level -> Level
emplaceEntrance point model =
  { model | entrance = Just (point, False)
          , upstairs = Nothing
          }
          |> addWallsAround point
          |> removeWall point

removeWall pt model =
  let
    walls' =
      model.walls |> List.filterMap (\pt' ->
        if not (pt == pt') then Just pt' else Nothing)
  in
  { model | walls = walls' }

removeFloor pt model =
  let
    floors' =
      model.floors
      |> List.filterMap (\pt' ->
        if not (pt == pt') then Just pt' else Nothing)
  in
  { model | floors = floors' }

addWallsAround pt model =
  let
    newWalls =
      Direction.directions
      |> List.map (\d -> Point.slide d pt)
      |> List.filter (\wall ->
        not
          (model.floors |> List.any (\floor' -> wall == floor')) ||
          (model.walls |> List.any (\wall' -> wall == wall'))
      )
  in
     { model | walls = newWalls ++ model.walls }

dropCoins : Level -> Level
dropCoins model =
  let
    down =
      case model.downstairs of
        Just pt ->
          pt
        Nothing ->
          case model.crystal of
            Just (pt,_) ->
              pt
            Nothing ->
              origin

    up =
       case model.upstairs of
        Just pt ->
          pt
        Nothing ->
          case model.entrance of
            Just (pt,_) ->
              pt
            Nothing ->
              origin

    path' =
      model
      |> path up down
      |> Maybe.withDefault []
      |> List.tail |> Maybe.withDefault []
      |> List.reverse
      |> List.tail |> Maybe.withDefault []

    everyN = \n ls ->
      case (ls |> List.drop (n-1)) of
        [] ->
          []
        (head :: rest) ->
          head :: (everyN n rest)

    coins' =
      path' |> everyN (List.length path' // 3)
  in
    { model | coins = model.coins ++ coins' }

spawnCreatures : List Room -> Level -> Level
spawnCreatures rooms model =
  let
    creatures' =
      rooms
      |> List.map Room.center
      |> List.indexedMap (\n pt -> Creature.createMonkey n pt)
  in
    { model | creatures = creatures' }

-- pathfinding
path : Point -> Point -> Level -> Maybe (List Point)
path dst src model =
  Path.find dst src (movesFrom model)

movesFrom : Level -> Point -> List (Point, Direction)
movesFrom model point =
  Direction.directions
  |> List.map (\direction -> (Point.slide direction point, direction))
  |> List.filter ((\p -> not (isBlocked p model)) << fst)

