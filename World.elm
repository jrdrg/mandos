module World exposing (Model, init, view, playerSteps, floors, walls, doors, coins, downstairs, upstairs, entrances, crystals, playerViewsField, playerDropsItem, entityAt, viewed, canPlayerStep, creatures, items, doesPlayerHaveCrystal, augmentVision, enchantItem, playerSheathesWeapon, playerTakesOff, playerWields, playerWears, playerDrinks, deathEvent, viewFrontier, playerLearnsWord, hitCreatureAt)

import Palette
import Point exposing (Point, slide)
import Direction exposing (Direction)
import Optics
import Creature
import Warrior
import Weapon
import Armor
import Ring
import Helm
import Entity exposing (Entity)
import Room exposing (Room)
import Dungeon exposing (Dungeon)
import Level exposing (Level)
import Path
import Log
import Event exposing (..)
import Util
import Configuration
import Item exposing (Item)
import Inventory
import Spell exposing (Spell(..))
import Language exposing (Language, Word)
import Liquid

import Set exposing (Set)
import String
import Html
import Graphics
import Svg
import Random

type alias Model =
  {
    depth : Int
  , dungeon : Dungeon
  , player : Warrior.Model
  , events : Log.Model
  , debugPath : List Point
  , illuminated : Set Point
  , hallsEscaped : Bool
  , showMap : Bool
  , age : Int
  , language : Language
  , animateEntities : List Entity
  }

-- INIT
init : Model
init =
  {
    dungeon = []
  , depth = 0
  , player = Warrior.init (0,0)
  , events = Log.init
  , debugPath = []
  , illuminated = Set.empty --[]
  , hallsEscaped = False
  , showMap = False
  , age = 0
  , language = []
  , animateEntities = []
  }


level : Model -> Level
level model =
  Util.getAt model.dungeon model.depth
  |> Maybe.withDefault Level.init

viewed : Model -> Set Point
viewed model =
  let lvl = (level model) in
  lvl.viewed

walls : Model -> Set Point
walls model =
  (level model).walls

coins : Model -> List Point
coins model =
  (level model).coins
  |> Set.toList

creatures : Model -> List Creature.Model
creatures model =
  (level model).creatures

items : Model -> List Item
items model =
  (level model).items

doors : Model -> Set Point
doors model =
  (level model).doors

floors : Model -> Set Point
floors model =
  (level model).floors

upstairs : Model -> List Point
upstairs model =
  case (level model).upstairs of
    Just pt -> [pt]
    Nothing -> []

downstairs : Model -> List Point
downstairs model =
  case (level model).downstairs of
    Just pt -> [pt]
    Nothing -> []

entrances : Model -> List Point
entrances model =
  case (level model).entrance of
    Just (pt,_) -> [pt]
    Nothing -> []

crystals : Model -> List Point
crystals model =
  let location = (level model) |> Level.crystalLocation in
  case location of
    Just pt -> [pt]
    Nothing -> []

-- PREDICATES/QUERIES

isPlayer : Point -> Model -> Bool
isPlayer position model =
  model.player.position == position

entityAt : Point -> Model -> Maybe Entity
entityAt pt model =
  Level.entityAt pt (level model)

-- PLAYER STEP
playerSteps : Direction -> Model -> Model
playerSteps direction model =
  model
  |> playerDestroysWalls direction
  |> playerMoves direction
  |> playerAttacks direction
  |> evolve

age : Model -> Model
age model =
  { model | age = model.age + 1 }

evolve : Model -> Model
evolve model =
  if model.age % 250 == 0 then
     { model | dungeon = model.dungeon |> Dungeon.evolve }
             |> age
  else
    model
    |> age

playerMoves : Direction -> Model -> Model
playerMoves direction model =
  if (canPlayerStep direction model) then
    { model | player = (Warrior.step direction model.player) }
    |> playerAscendsOrDescends
    |> playerEscapesHall
    |> playerCollectsCoins
    |> playerCollectsItems
  else
    model

canPlayerStep : Direction -> Model -> Bool
canPlayerStep direction model =
  let
    move =
      model.player.position
      |> slide direction
  in
    not ( Level.isCreature move (level model) || Set.member move (walls model))

playerCollectsCoins : Model -> Model
playerCollectsCoins model =
  let
    isCoin =
      level model
      |> Level.isCoin model.player.position

    dungeon' =
      model.dungeon
      |> Dungeon.collectCoin model.player.position model.depth
  in
    if (not isCoin) then
      model
    else
      let event = Event.pickupCoin in
        { model | player  = Warrior.enrich 1 model.player
                , dungeon = dungeon'
                , events  = model.events ++ [event]
        }

doesPlayerHaveCrystal model =
  model.player.inventory
  |> List.any (\{kind} -> kind == Item.crystal)

playerEscapesHall : Model -> Model
playerEscapesHall model =
  let
    isEntrance =
      level model
      |> Level.isEntrance model.player.position

  in
    if (model |> doesPlayerHaveCrystal) && isEntrance then
      let event = Event.hallsEscaped in
      { model | hallsEscaped = True
              , events = model.events ++ [event]
      }
    else
      model

playerAttacks : Direction -> Model -> Model
playerAttacks direction model =
  let
    {player} =
       model

    attackedPositions =
      case player.weapon of
        Just weapon ->
          Weapon.threatRange player.position direction weapon

        Nothing ->
          [ player.position |> slide direction ]

    creatures =
      attackedPositions
      |> List.map (\pt -> (level model) |> Level.creatureAt pt)
      |> List.filterMap identity
  in
    creatures
    |> List.foldr (\creature -> playerAttacksCreature creature) model
    |> removeDeceasedCreatures

playerAttacksCreature : Creature.Model -> Model -> Model
playerAttacksCreature creature model =
  let
    damage =
      Warrior.computeDamageAgainst creature.defense model.player
  in
    model
    |> creatureTakesDamage creature damage

creatureTakesDamage : Creature.Model -> Int -> Model -> Model
creatureTakesDamage creature amount model =
  let
    dungeon' =
      model.dungeon
      |> Dungeon.injureCreature creature amount model.depth

    attackEvent =
      Event.attack creature amount
  in
    { model | dungeon = dungeon'
            , events = model.events ++ [attackEvent]
    }

removeDeceasedCreatures : Model -> Model
removeDeceasedCreatures model =
  let
    (dungeon', events') =
      Dungeon.purge model.depth model.dungeon
  in
    { model | dungeon = dungeon'
            , events = model.events ++ events' }

playerDestroysWalls : Direction -> Model -> Model
playerDestroysWalls direction model =
  let
    pt =
      model.player.position
      |> Point.slide direction

    isWall =
      Set.member pt (walls model)

    destructive =
      case model.player.weapon of
        Just weapon ->
          Weapon.destroyWalls weapon
        Nothing ->
          False

    dungeon' =
      model.dungeon
      |> Dungeon.playerDestroysWall pt model.depth

  in
    if isWall && destructive then
      { model | dungeon = dungeon'
              , player = model.player |> Warrior.step direction }
    else
      model

playerAscendsOrDescends : Model -> Model
playerAscendsOrDescends model =
  let
    playerPos =
      model.player.position
  in
    if List.member playerPos (downstairs model) && model.depth < ((List.length model.dungeon) - 1) then
      model |> playerDescends
    else
      if List.member playerPos (upstairs model) && model.depth > 0 then
        model |> playerAscends
      else
        model

playerAscends : Model -> Model
playerAscends model =
  let
    player =
      model.player

    model' =
      { model | depth = model.depth - 1 }

    player' =
      { player | position = (downstairs model') |> List.head |> Maybe.withDefault (0,0) }

    events' =
      model.events ++ [Event.ascend (model.depth-1)]
  in
    { model' | player = player' }

playerDescends : Model -> Model
playerDescends model =
  let
    player =
      model.player

    model' =
      { model | depth = model.depth + 1 }

    player' =
      { player | position = (upstairs model') |> List.head |> Maybe.withDefault (0,0) }

    events' =
      model.events ++ [Event.descend (model.depth+1)]
  in
    { model' | player = player', events = events' }

playerViewsField : Model -> Model
playerViewsField model =
  let
    source =
      model.player.position

    locations =
      model |> illuminate source
  in
    { model | dungeon = model.dungeon |> Dungeon.playerSees locations model.depth
            , illuminated = locations
    }

illuminate : Point -> Model -> Set Point
illuminate source model =
  let
    perimeter =
      Point.perimeter (1,1) Configuration.viewWidth Configuration.viewHeight
      |> Set.toList

    blockers =
      (creatures model)
      |> List.map .position
      |> Set.fromList
      |> Set.union (Set.union (walls model) (doors model))

    power =
      Warrior.vision model.player

  in
    source
    |> Optics.illuminate power perimeter blockers

playerCollectsItems : Model -> Model
playerCollectsItems model =
  if Inventory.size model.player < Configuration.inventoryLimit then
    case (level model) |> Level.itemAt (model.player.position) of
      Nothing ->
        model

      Just item ->
        let event = Event.pickupItem item in
        { model | player  = Warrior.collectsItem item model.player
                , dungeon = model.dungeon |> Dungeon.removeItem item model.depth
                , events  = model.events ++ [ event ]
        }
  else
    model

playerDropsItem : Item -> Model -> Model
playerDropsItem item model =
  let
    inventory' =
      model.player.inventory
      |> List.filter (\it -> not (it == item))

    player =
      model.player

    player' =
      { player | inventory = inventory' }
  in
    { model | player = player' }

playerWields : Item -> Model -> Model
playerWields item model =
  case item.kind of
    Item.Arm weapon ->
      { model | player = model.player |> Warrior.wield weapon }

    _ -> model

playerWears : Item -> Model -> Model
playerWears item model =
  case item.kind of
    Item.Shield armor ->
      { model | player = model.player |> Warrior.wearArmor armor }

    Item.Jewelry ring ->
      let
        player' =
          model.player
          |> Warrior.wearRing ring

        word =
          model.language
          |> Language.wordFor (Spell.idea (Ring.spell ring))
      in
        { model | player = player' }
                |> playerViewsField -- could be ring of light..
                |> playerLearnsWord word

    Item.Headgear helm ->
      { model | player = model.player |> Warrior.wearHelm helm }

    _ -> model

playerTakesOff item model =
  case item.kind of
    Item.Shield armor ->
      { model | player = model.player |> Warrior.takeOffArmor }

    Item.Jewelry ring ->
      { model | player = model.player |> Warrior.takeOffRing }
              |> playerViewsField

    Item.Headgear helm ->
      { model | player = model.player |> Warrior.takeOffHelm }

    _ -> model


playerDrinks : Item -> Model -> Model
playerDrinks item model =
  case item.kind of
    Item.Bottle liquid ->
      let
        player' =
          model.player
          |> Warrior.drink liquid

        word =
          Language.wordFor (Liquid.idea liquid) model.language
      in
        { model | player = player' }
                |> playerLearnsWord word

    _ -> model

playerLearnsWord : Word -> Model -> Model
playerLearnsWord word model =
  { model | player = model.player |> Warrior.learnsWord word }

playerSheathesWeapon : Model -> Model
playerSheathesWeapon model =
  { model | player = model.player |> Warrior.sheatheWeapon }

augmentVision : Model -> Model
augmentVision model =
  { model | player = model.player |> Warrior.augmentVision 1 }

enchantItem : Item -> Model -> Model
enchantItem item model =
  let
    player =
      model.player

    inventory' =
      player.inventory
      |> List.map (\it -> if it == item then Item.enchant it else it)

    weapon' =
      case player.weapon of
        Just weapon ->
          if Item.simple (Item.weapon weapon) == item then
            Just (Weapon.enchant weapon)
          else
            Just weapon

        Nothing ->
          Nothing

    armor' =
      case player.armor of
        Just armor ->
          if Item.simple (Item.armor armor) == item then
            Just (Armor.enchant armor)
          else
            Just armor

        Nothing ->
          Nothing

    ring' =
      case player.ring of
        Just ring ->
          if Item.simple (Item.ring ring) == item then
            Just (Ring.enchant ring)
          else
            Just ring
        Nothing ->
          Nothing

    helm' =
      case player.helm of
        Just helm ->
          if Item.simple (Item.helm helm) == item then
            Just (Helm.enchant helm)
          else
            Just helm

        Nothing ->
          Nothing

    player' =
      { player | inventory = inventory'
               , armor = armor'
               , weapon = weapon'
               , ring = ring'
               , helm = helm'
      }
  in
    { model | player = player' }
            |> playerViewsField -- could be enchanting ring of light..


hitCreatureAt : Point -> Item -> Model -> Model
hitCreatureAt pt item model =
  case (level model) |> Level.creatureAt pt of
    Just creature ->
      let
        (dungeon', events) =
          model.dungeon
          |> Dungeon.apply (Level.hitCreatureWith item creature) model.depth
          |> Dungeon.purge model.depth
          -- todo need event here if we hit something...

        newEvents =
          (Event.attack creature (Item.thrownDamage item)) :: events

        model' =
          { model | dungeon = dungeon'
                  , events  = model.events ++ newEvents
                  }
      in
         -- we could have killed a creature (destroyed a view obstacle)
         model'
         |> playerViewsField

    Nothing ->
      model

 --model

deathEvent : Model -> Maybe Event
deathEvent model =
  model.events
  |> List.filter (Event.isPlayerDeath)
  |> List.head


viewFrontier : Model -> Set Point
viewFrontier model =
  model.dungeon
  |> Dungeon.viewFrontier model.depth

-- VIEW
listInvisibleEntities : Model -> List Entity
listInvisibleEntities model =
  if not model.showMap then
    []
  else
    let explorable = (Set.union (model |> floors) (model |> walls)) in
    viewed model
    |> Set.diff explorable
    |> Set.toList
    |> List.filterMap (\pt -> model |> entityAt pt)
    |> List.map (Entity.imaginary)

-- todo try to optimize further -- almost 10% of our time is spent here :/
listRememberedEntities : Model -> List Entity
listRememberedEntities model =
  model.illuminated
  |> Set.diff (viewed model)
  |> Set.toList
  |> List.filterMap (\pt -> model |> entityAt pt)
  |> List.map (Entity.memory)

listEntities : Model -> List Entity
listEntities model =
  let
    litEntities =
      model.illuminated
      |> Set.toList
      |> List.filterMap (\pt -> model |> entityAt pt)

    memoryEntities =
      model
      |> listRememberedEntities

  in
    memoryEntities ++
    listInvisibleEntities model ++
    litEntities ++
    [Entity.player model.player]

view : Model -> List (Svg.Svg a)
view model =
  let
    entities =
      listEntities model
      ++ model.animateEntities

    entityViews =
      List.map (Entity.view) entities

    highlight =
      highlightCells model.debugPath
  in
    entityViews
    ++ highlight

highlightCells : List Point -> List (Svg.Svg a)
highlightCells cells =
  let
    pathColor =
      Palette.tertiary' 2 0.7
    targetColor =
      Palette.tertiary' 0 0.7
  in

    case cells of
      [] -> []
      [x] -> [highlightCell x targetColor]
      a :: b :: _ ->
        let
          tail =
            case (List.tail cells) of
              Nothing -> []
              Just rest -> highlightCells rest
        in
          (highlightCell a pathColor) :: tail

highlightCell (x,y) color =
  Graphics.render "@" (x,y) color
