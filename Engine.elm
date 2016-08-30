module Engine exposing (Engine, init, view, enter, clickAt, hoverAt, tick, handleKeypress, resetHover)

import Point exposing (Point, slide)
import Direction exposing (Direction(..))
import Path
import World
import Dungeon exposing (Dungeon)
import Entity exposing (Entity)
import Configuration
import Util
import Graphics
import Warrior
import Quest exposing (Quest)
import Journal
import Log
import Status
import Item

import Set exposing (Set)
import Time
import Mouse
import Svg exposing (svg, rect, text')
import Svg.Attributes exposing (viewBox, width, height, x, y, fontSize, fontFamily)
import Svg.Events

type alias Engine =
  { world : World.Model
  , hover : Maybe Entity
  , hoverPath : List Point
  , followPath : Maybe (List Point)
  , auto : Bool
  , telepathy : Bool
  , quests : List Quest
  }

init : Engine
init =
  { world = World.init
  , hover = Nothing
  , hoverPath = []
  , followPath = Nothing
  , auto = False
  , telepathy = False
  , quests = Quest.coreCampaign --[ Quest.findCrystal ]
  }

enter : Dungeon -> Engine -> Engine
enter dungeon model =
  let
    dungeon' =
      dungeon |> Dungeon.prepare

    world =
      model.world

    player =
      world.player

    startPos =
      case (Dungeon.levelAt 0 dungeon').entrance of
        Just (pt,_) -> pt
        Nothing -> (10,10)

    player' =
      { player | position = startPos }

    world' =
      { world | dungeon = dungeon'
              , depth = 0
              , player = player'
      }
  in
  ({ model | world = world' |> World.playerViewsField
   })

illuminate : Engine -> Engine
illuminate model =
  { model | world = World.playerViewsField model.world }

handleKeypress : Char -> Engine -> Engine
handleKeypress keyChar model =
  let
    reset = (
      resetFollow << 
      resetAuto << 
      illuminate << 
      moveCreatures
    ) 
  in
    model |> case keyChar of
      'a' -> autorogue
      'h' -> reset << playerSteps West
      'j' -> reset << playerSteps South
      'k' -> reset << playerSteps North
      'l' -> reset << playerSteps East
      't' -> telepath
      'x' -> playerExplores
      _ -> reset

tick : Time.Time -> Engine -> Engine
tick time model =
  model 
  |> followPaths
  |> updateQuests 

updateQuests : Engine -> Engine
updateQuests model =
  -- check if we've unlocked any quests...
  let
    quests' =
      model.quests
      |> Quest.unlocked model.world
  in
    { model | quests = quests' ++ model.quests }

followPaths : Engine -> Engine
followPaths model =
  case model.followPath of
    Nothing ->
      if model.auto then
        model
        |> playerExplores
      else
        model

    Just path ->
      model
      |> playerFollowsPath

autorogue model =
  { model | auto = True }

telepath model =
  if model.telepathy then
    { model | telepathy = False }
  else
    --Debug.log "TELEPATH!"
    { model | telepathy = True }

moveCreatures model =
  let
    world =
      model.world

    (dungeon', events, player') =
      world.dungeon
      |> Dungeon.moveCreatures world.player world.depth

    world' =
      { world | dungeon = dungeon'
              , events = world.events ++ List.reverse events
              , player = player'
      }

  in
    --Debug.log "MOVE CREATURES!"
    { model | world = world' }

playerSteps direction model =
  { model | world = model.world |> World.playerSteps direction }

resetHover : Engine -> Engine
resetHover model =
  { model | hoverPath = []
          , hover = Nothing }

resetFollow : Engine -> Engine
resetFollow model =
  { model | followPath = Nothing }

resetAuto : Engine -> Engine
resetAuto model =
  { model | auto = False }

-- maybe to utils?
screenToCoordinate : Mouse.Position -> Point
screenToCoordinate {x,y} =
  let scale = Configuration.viewScale in
  ( x//scale
  , (y//scale)+1 -- ignore top bar ...
  )

hoverAt : Mouse.Position -> Engine -> Engine
hoverAt position model =
  --model
  let
    point =
      (screenToCoordinate position)

    isLit =
      List.member point (model.world.illuminated)

    wasLit =
      List.member point (World.viewed model.world)
  in
    if isLit then
      model |> seeEntityAt point
    else
      if wasLit then
        model |> rememberEntityAt point
      else
        if model.telepathy then
          model |> imagineEntityAt point
        else
          model

seeEntityAt point model =
  let
    entities =
      World.entitiesAt point model.world

    maybeEntity =
      entities
      |> List.reverse
      |> List.head

    path' =
      case maybeEntity of
        Nothing ->
          []

        Just entity ->
          model |> pathToEntity entity

  in
      { model | hover = maybeEntity
              , hoverPath = path'
      }

rememberEntityAt point model =
  let
    entity =
      World.entitiesAt point model.world
      |> List.filter (not << Entity.isCreature)
      |> List.reverse
      |> List.head

    maybeEntity =
      case entity of
         Just entity' ->
           Just (Entity.memory entity')
         Nothing ->
           Nothing

    path' =
      case maybeEntity of
        Nothing ->
          []

        Just entity ->
          model |> pathToEntity entity
    in
      { model | hover = maybeEntity
              , hoverPath = path'
      }


imagineEntityAt point model =
  let
    entity =
      World.entitiesAt point model.world
      |> List.reverse
      |> List.head

    maybeEntity =
      case entity of
        Just entity' ->
          Just (Entity.imaginary entity')
        Nothing ->
          Nothing

    path' =
      case maybeEntity of
        Nothing ->
          []

        Just entity ->
          model |> pathToEntity entity
  in
    { model | hover = maybeEntity
            , hoverPath = path' 
    }

pathToEntity entity model =
  let
    entityPos =
      Entity.position entity

    playerPos =
      model.world.player.position

    alreadyHovering =
      case model.hover of
        Just entity' ->
          entity' == entity
        Nothing -> False

  in
    if alreadyHovering || not (model.followPath == Nothing) then
      model.hoverPath
    else
      Path.seek entityPos playerPos (\pt -> Set.member pt (World.walls model.world))


clickAt : Mouse.Position -> Engine -> Engine
clickAt _ model =
  case model.followPath of
    Nothing ->
      { model | followPath = Just model.hoverPath }
    Just path ->
      model

playerFollowsPath : Engine -> Engine
playerFollowsPath model =
  case model.followPath of
    Nothing -> model
    Just path ->
      case (List.head path) of
        Nothing ->
          model
          |> resetHover
          |> resetFollow

        Just nextStep ->
          let
            playerPos =
              model.world.player.position

            direction =
              (Point.towards nextStep playerPos)

            onPath =
              nextStep == (playerPos |> slide direction)

            followPath' =
              List.tail path
          in
            if onPath then
              ({model | followPath = followPath' })
              |> playerSteps direction
              |> moveCreatures
              |> illuminate
            else
              model
              |> resetFollow
              |> resetHover

--viewed model = World.viewed model.world

playerExplores : Engine -> Engine
playerExplores model =
  let
    playerPos =
      model.world.player.position

    byDistanceFromPlayer =
      (\c -> Point.distance playerPos c)

    (explored,unexplored) =
      let v = (World.viewed model.world) in
      model.world
      |> World.floors
      |> Set.toList
      |> List.partition (\p -> List.member p v)

    frontier =
      explored
      |> List.filter (\pt ->
        List.any (\pt' -> Point.isAdjacent pt pt') unexplored)

    visibleCreatures =
      (World.creatures model.world)
      |> List.map .position
      |> List.filter (\pt -> List.member pt (explored))

    visibleCoins =
      (World.coins model.world)
      |> List.filter (\pt -> List.member pt (explored))

    visibleItems =
      (World.items model.world)
      |> List.map Item.position
      |> List.filter (\pt -> List.member pt (explored))

    destSources =
      if List.length visibleCreatures > 0 then
        visibleCreatures
      else
        if List.length visibleCoins > 0 then
          visibleCoins
        else
          if List.length visibleItems > 0 then
            visibleItems
          else
            if model.world.crystalTaken then
              World.upstairs model.world ++ World.entrances model.world
            else
              if List.length frontier > 0 then
                frontier
              else
                World.downstairs model.world ++ World.crystals model.world

    maybeDest =
      destSources
      |> List.sortBy byDistanceFromPlayer
      |> List.head

    path =
      case maybeDest of
        Nothing ->
          Nothing

        Just dest ->
          let
            path' =
              Path.seek dest playerPos (\pt ->
                Set.member pt (World.walls model.world))
          in
            if List.length path' == 0 then
              Nothing
            else
              Just path'
  in
    { model | followPath = path }

-- VIEW

view : Engine -> List (Svg.Svg a)
view model =
  let
    world =
      model.world

    path =
      case model.followPath of
        Nothing -> model.hoverPath
        Just path -> path

    worldView =
      World.view { world | debugPath = path
                         , showMap = model.telepathy
                         }

    debugMsg =
      case model.hover of
        Nothing ->
          "You aren't looking at anything in particular."

        Just entity ->
          case entity of
            Entity.Memory e ->
              "You remember seeing " ++ (Entity.describe e) ++ " here."
            Entity.Imaginary e ->
              "You imagine there to be " ++ (Entity.describe e) ++ " here."
            _ ->
              "You see " ++ (Entity.describe entity) ++ "."

    note =
      Graphics.render debugMsg (25,1) "rgba(160,160,160,0.6)"

    quests =
      Journal.view (55,2) model.world model.quests

    character =
      Warrior.cardView (55, 6 + (List.length model.quests)) model.world.player

    log =
      Log.view (2, 35) model.world.events

    status =
      Status.view (0,1) model.world

    rightBar =
      quests 
      ++ character 
      ++ log
  in
    worldView 
    ++ [status, note]
    ++ rightBar
