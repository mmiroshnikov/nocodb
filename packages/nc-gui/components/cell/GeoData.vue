<script lang="ts" setup>
import 'leaflet/dist/leaflet.css'
import L from 'leaflet'
import { type GeoLocationType, convertGeoNumberToString, latLongToJoinedString } from 'nocodb-sdk'
import { useDebounceFn } from '@vueuse/core'

interface Props {
  modelValue?: string | null
}

interface Emits {
  (event: 'update:modelValue', model: GeoLocationType): void
}

const props = defineProps<Props>()

const emits = defineEmits<Emits>()

const column = inject(ColumnInj)

const { tileUrl, attribution } = useMapConfig()

const vModel = useVModel(props, 'modelValue', emits)

const activeCell = inject(ActiveCellInj, ref(false))

const isPublic = inject(IsPublicInj, ref(false))

const readonly = inject(ReadonlyInj, ref(false))

const isLinkRecordDropdown = inject(IsLinkRecordDropdownInj, ref(false))

const isExpanded = ref(false)

const isLoading = ref(false)

// --- Map picker state ---
const mapContainerRef = ref<HTMLElement>()
const mapInstanceRef = ref<L.Map>()
const markerRef = ref<L.Marker>()
const isUpdatingFromMap = ref(false)

const DEFAULT_CENTER: [number, number] = [20, 0]
const DEFAULT_ZOOM = 2
const LOCATION_ZOOM = 15
const AUTO_POSITION_ZOOM = 10

const [latitude, longitude] = (vModel.value || '').split(';')

const formState = reactive({
  latitude,
  longitude,
})

function syncToFormState(lat: number, lng: number) {
  isUpdatingFromMap.value = true
  formState.latitude = convertGeoNumberToString(lat)
  formState.longitude = convertGeoNumberToString(lng)
  nextTick(() => {
    isUpdatingFromMap.value = false
  })
}

function setupMarkerDrag(marker: L.Marker) {
  marker.on('dragend', () => {
    const pos = marker.getLatLng()
    syncToFormState(pos.lat, pos.lng)
  })
}

function updateMarkerPosition(lat: number, lng: number) {
  if (!mapInstanceRef.value) return
  if (markerRef.value) {
    markerRef.value.setLatLng([lat, lng])
  } else {
    const marker = L.marker([lat, lng], { draggable: !readonly.value }).addTo(mapInstanceRef.value)
    setupMarkerDrag(marker)
    markerRef.value = marker
  }
}

function onMapClick(e: L.LeafletMouseEvent) {
  if (readonly.value) return
  const { lat, lng } = e.latlng
  updateMarkerPosition(lat, lng)
  syncToFormState(lat, lng)
}

function initMap() {
  if (!mapContainerRef.value || mapInstanceRef.value) return

  const hasCoords = formState.latitude && formState.longitude
  const lat = parseFloat(formState.latitude)
  const lng = parseFloat(formState.longitude)
  const validCoords = hasCoords && !isNaN(lat) && !isNaN(lng) && lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180
  const center: [number, number] = validCoords ? [lat, lng] : DEFAULT_CENTER
  const zoom = validCoords ? LOCATION_ZOOM : DEFAULT_ZOOM

  const map = L.map(mapContainerRef.value, {
    center,
    zoom,
    zoomControl: false,
    attributionControl: true,
  })

  L.control.zoom({ position: 'bottomleft' }).addTo(map)

  L.tileLayer(tileUrl.value, {
    maxZoom: 19,
    attribution: attribution.value,
  }).addTo(map)

  if (validCoords) {
    const marker = L.marker(center, { draggable: !readonly.value }).addTo(map)
    setupMarkerDrag(marker)
    markerRef.value = marker
  } else {
    // No saved coordinates - try auto-positioning with geolocation
    tryAutoPositionMap()
  }

  map.on('click', onMapClick)
  mapInstanceRef.value = map
}

function tryAutoPositionMap() {
  if (!navigator.geolocation) return

  const onSuccess: PositionCallback = (position: GeolocationPosition) => {
    // Guard: only update if map still exists (user might have closed overlay)
    if (!mapInstanceRef.value) return

    const { latitude, longitude } = position.coords
    mapInstanceRef.value.setView([latitude, longitude], AUTO_POSITION_ZOOM)
  }

  const onError: PositionErrorCallback = (err: GeolocationPositionError) => {
    // Silent failure - common for denied permissions
    console.debug(`Geolocation auto-position skipped: ${err.code}`)
  }

  const options: PositionOptions = {
    enableHighAccuracy: true,
    timeout: 20000,
    maximumAge: 2000,
  }

  navigator.geolocation.getCurrentPosition(onSuccess, onError, options)
}

function destroyMap() {
  if (mapInstanceRef.value) {
    mapInstanceRef.value.remove()
    mapInstanceRef.value = undefined
    markerRef.value = undefined
  }
}

// --- City search (GeoNames via OpenDataSoft public API) ---
interface GeoNamesCity {
  geoname_id: string
  name: string
  ascii_name: string | null
  cou_name_en: string | null
  country_code: string | null
  population: number | null
  coordinates: { lat: number; lon: number } | null
}

interface GeoNamesResponse {
  total_count: number
  results: GeoNamesCity[]
}

const searchQuery = ref('')
const searchResults = ref<GeoNamesCity[]>([])
const isSearching = ref(false)
const showSearchResults = ref(false)
const highlightedIndex = ref(-1)
const searchInputRef = ref<HTMLInputElement>()
const skipNextSearch = ref(false)

const GEONAMES_API =
  'https://public.opendatasoft.com/api/explore/v2.1/catalog/datasets/geonames-all-cities-with-a-population-1000/records'

let searchAbortController: AbortController | null = null
let searchBlurTimer: ReturnType<typeof setTimeout> | null = null
let copyTooltipTimer: ReturnType<typeof setTimeout> | null = null

function escapeOdsqlString(value: string): string {
  return value.replace(/["\\\n\r]/g, ' ').replace(/\s+/g, ' ').trim()
}

function cityLabel(city: GeoNamesCity): string {
  return city.cou_name_en ? `${city.name}, ${city.cou_name_en}` : city.name
}

function formatPopulation(population: number | null): string {
  if (!population) return ''
  if (population >= 1_000_000) {
    const millions = population / 1_000_000
    return `${millions >= 10 ? millions.toFixed(0) : millions.toFixed(1)}M`
  }
  if (population >= 1_000) return `${Math.round(population / 1_000)}K`
  return population.toLocaleString()
}

const performSearch = useDebounceFn(async () => {
  const query = escapeOdsqlString(searchQuery.value)
  if (query.length < 2) {
    searchResults.value = []
    showSearchResults.value = false
    highlightedIndex.value = -1
    return
  }

  searchAbortController?.abort()
  searchAbortController = new AbortController()

  isSearching.value = true
  try {
    const isAsciiQuery = /^[\u0020-\u007E]+$/.test(query)
    const clauses = [`suggest(name, "${query}")`, `suggest(ascii_name, "${query}")`]
    // Full-text on alternate names is needed for non-Latin input ("Москва", "Усть-Каменогорск")
    // but is too noisy for short Latin prefixes.
    if (!isAsciiQuery) {
      clauses.push(
        `search(name, "${query}")`,
        `search(ascii_name, "${query}")`,
        `search(alternate_names, "${query}")`,
      )
    }
    const params = new URLSearchParams({
      where: clauses.join(' OR '),
      order_by: 'population desc',
      limit: '8',
      select: 'geoname_id,name,ascii_name,cou_name_en,country_code,population,coordinates',
    })

    const response = await fetch(`${GEONAMES_API}?${params.toString()}`, {
      signal: searchAbortController.signal,
    })

    if (!response.ok) throw new Error('City search request failed')

    const data: GeoNamesResponse = await response.json()
    const seen = new Set<string>()
    searchResults.value = (data.results || []).filter((city) => {
      if (!city?.geoname_id || seen.has(city.geoname_id)) return false
      seen.add(city.geoname_id)
      return true
    })
    showSearchResults.value = true
    highlightedIndex.value = searchResults.value.length ? 0 : -1
  } catch (err: unknown) {
    if (err instanceof DOMException && err.name === 'AbortError') return
    console.error('City search error:', err)
    searchResults.value = []
    showSearchResults.value = true
    highlightedIndex.value = -1
  } finally {
    isSearching.value = false
  }
}, 300)

function applyCityCoordinates(city: GeoNamesCity) {
  const lat = city.coordinates?.lat
  const lng = city.coordinates?.lon
  if (typeof lat !== 'number' || typeof lng !== 'number') return

  syncToFormState(lat, lng)
  updateMarkerPosition(lat, lng)
  mapInstanceRef.value?.setView([lat, lng], LOCATION_ZOOM)
}

function selectSearchResult(city: GeoNamesCity) {
  applyCityCoordinates(city)
  skipNextSearch.value = true
  searchQuery.value = cityLabel(city)
  showSearchResults.value = false
  highlightedIndex.value = -1
}

function onSearchKeydown(e: KeyboardEvent) {
  if (e.key === 'Escape' && showSearchResults.value) {
    e.preventDefault()
    e.stopPropagation()
    showSearchResults.value = false
    return
  }

  if (e.key === 'ArrowDown') {
    e.preventDefault()
    e.stopPropagation()
    if (!searchResults.value.length) return
    showSearchResults.value = true
    highlightedIndex.value = (highlightedIndex.value + 1) % searchResults.value.length
    return
  }

  if (e.key === 'ArrowUp') {
    e.preventDefault()
    e.stopPropagation()
    if (!searchResults.value.length) return
    showSearchResults.value = true
    highlightedIndex.value = highlightedIndex.value <= 0 ? searchResults.value.length - 1 : highlightedIndex.value - 1
    return
  }

  if (e.key === 'Enter') {
    e.preventDefault()
    e.stopPropagation()
    const selected = searchResults.value[highlightedIndex.value]
    if (selected && showSearchResults.value) {
      selectSearchResult(selected)
    }
  }
}

function onSearchBlur() {
  if (searchBlurTimer) clearTimeout(searchBlurTimer)
  searchBlurTimer = setTimeout(() => {
    showSearchResults.value = false
  }, 200)
}

function resetCitySearch() {
  searchQuery.value = ''
  searchResults.value = []
  showSearchResults.value = false
  highlightedIndex.value = -1
  skipNextSearch.value = false
}

watch(searchQuery, () => {
  if (skipNextSearch.value) {
    skipNextSearch.value = false
    return
  }
  if (searchQuery.value.trim().length >= 2) {
    performSearch()
  } else {
    searchResults.value = []
    showSearchResults.value = false
    highlightedIndex.value = -1
  }
})

// Debounced sync: input fields -> map
const syncMapFromInputs = useDebounceFn(() => {
  if (isUpdatingFromMap.value || !mapInstanceRef.value) return

  const lat = parseFloat(formState.latitude)
  const lng = parseFloat(formState.longitude)
  if (isNaN(lat) || isNaN(lng)) return
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return

  updateMarkerPosition(lat, lng)
  mapInstanceRef.value.setView([lat, lng], Math.max(mapInstanceRef.value.getZoom(), LOCATION_ZOOM))
}, 500)

const identifier = {
  latitude: `nc-geo-lat-${Math.random().toString(36).substring(2, 10)}`,
  longitude: `nc-geo-lng-${Math.random().toString(36).substring(2, 10)}`,
  citySearch: `nc-geo-city-${Math.random().toString(36).substring(2, 10)}`,
}

const isLocationSet = computed(() => {
  return !!vModel.value
})

const { t } = useI18n()

const latLongStr = computed(() => {
  const [lat, lng] = (vModel.value || '').split(';')
  return lat && lng ? `${lat}; ${lng}` : t('labels.setLocation')
})

const isLatitudeInvalid = computed(() => {
  if (!formState.latitude) return false
  const lat = parseFloat(formState.latitude)
  return isNaN(lat) || lat < -90 || lat > 90
})

const isLongitudeInvalid = computed(() => {
  if (!formState.longitude) return false
  const lng = parseFloat(formState.longitude)
  return isNaN(lng) || lng < -180 || lng > 180
})

const handleFinish = () => {
  if (isLatitudeInvalid.value || isLongitudeInvalid.value) return
  vModel.value = latLongToJoinedString(parseFloat(formState.latitude), parseFloat(formState.longitude))
  isExpanded.value = false
}

const clear = () => {
  isExpanded.value = false

  formState.latitude = latitude
  formState.longitude = longitude
}

const clearValue = () => {
  vModel.value = null
  formState.latitude = ''
  formState.longitude = ''
  isExpanded.value = false
}

const onClickSetCurrentLocation = () => {
  isLoading.value = true
  const onSuccess: PositionCallback = (position: GeolocationPosition) => {
    const crd = position.coords
    formState.latitude = `${convertGeoNumberToString(crd.latitude)}`
    formState.longitude = `${convertGeoNumberToString(crd.longitude)}`
    isLoading.value = false
  }

  const onError: PositionErrorCallback = (err: GeolocationPositionError) => {
    console.error(`ERROR(${err.code}): ${err.message}`)
    isLoading.value = false
  }

  const options = {
    enableHighAccuracy: true,
    timeout: 20000,
    maximumAge: 2000,
  }
  navigator.geolocation.getCurrentPosition(onSuccess, onError, options)
}

const openInGoogleMaps = () => {
  const [latitude, longitude] = (vModel.value || '').split(';')
  if (!latitude || !longitude) return
  const url = `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(latitude)},${encodeURIComponent(longitude)}`
  window.open(url, '_blank', 'noopener,noreferrer')
}

const openInOSM = () => {
  const [latitude, longitude] = (vModel.value || '').split(';')
  if (!latitude || !longitude) return
  const url = `https://www.openstreetmap.org/?mlat=${encodeURIComponent(latitude)}&mlon=${encodeURIComponent(
    longitude,
  )}#map=15/${latitude}/${longitude}`
  window.open(url, '_blank', 'noopener,noreferrer')
}

const handleClose = (e: MouseEvent) => {
  if (e.target instanceof HTMLElement && !e.target.closest('.nc-geodata-picker-overlay')) {
    isExpanded.value = false
  }
}

useEventListener(document, 'click', handleClose, true)

/**
 * Parse a pasted string into "lat;lng" format.
 * Accepts: "lat;lng", "lat,lng", "lat, lng", or "lat lng"
 * Returns the normalised "lat;lng" string, or null if unparseable.
 */
function parseGeoString(raw: string): string | null {
  const trimmed = raw.trim()

  // Try convertCellData first (handles NocoDB internal formats) — but only when column metadata is available
  if (column?.value?.uidt) {
    try {
      const converted = convertCellData({ value: trimmed, to: column.value.uidt, column: column.value }, false)
      if (converted) return converted
    } catch {
      // fall through to manual parsing
    }
  }

  // Manual parsing: split on ; or , or whitespace
  const parts = trimmed.split(/[;,\s]+/).filter(Boolean)
  if (parts.length === 2) {
    const lat = parseFloat(parts[0])
    const lng = parseFloat(parts[1])
    if (!isNaN(lat) && !isNaN(lng) && lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180) {
      return `${convertGeoNumberToString(lat)};${convertGeoNumberToString(lng)}`
    }
  }
  return null
}

const isUnderLookup = inject(IsUnderLookupInj, ref(false))
const isCanvasInjected = inject(IsCanvasInjectionInj, false)
const isExpandedForm = inject(IsExpandedFormOpenInj, ref(false))
const isGrid = inject(IsGridInj, ref(false))
const isEditColumn = inject(EditColumnInj, ref(false))
const isForm = inject(IsFormInj, ref(false))

const handlePaste = (e: ClipboardEvent) => {
  if ([identifier.latitude, identifier.longitude].includes(e.target?.id)) {
    return
  }
  const clipboardData = e.clipboardData?.getData('text/plain') || ''
  if (!clipboardData) return

  // Allow paste both when overlay is open AND when in expanded form (overlay may be closed)
  if (isExpanded.value || isExpandedForm.value) {
    const value = parseGeoString(clipboardData)
    if (value) {
      const pastedLat = value.split(';')[0]
      const pastedLng = value.split(';')[1]
      formState.latitude = pastedLat
      formState.longitude = pastedLng

      // In expanded form with overlay closed, commit directly
      if (isExpandedForm.value && !isExpanded.value) {
        e.preventDefault()
        vModel.value = latLongToJoinedString(parseFloat(pastedLat), parseFloat(pastedLng))
      }
    }
  }
}

const handleBlur = (e: Event) => {
  const target = e.target as HTMLInputElement
  const originalValue = target.value
  const value = convertGeoNumberToString(Number(originalValue))
  if (value !== originalValue) {
    if (target.id === identifier.latitude) {
      formState.latitude = value
    } else if (target.id === identifier.longitude) {
      formState.longitude = value
    }
  }
}

onMounted(() => {
  if (!isUnderLookup.value && isCanvasInjected && !isExpandedForm.value && isGrid.value && !isEditColumn.value) {
    forcedNextTick(() => {
      isExpanded.value = true
    })
  }
})

watch(
  () => vModel,
  (newValue) => {
    if (newValue.value) {
      formState.latitude = newValue.value?.split(';')[0]
      formState.longitude = newValue.value?.split(';')[1]
    } else {
      formState.latitude = ''
      formState.longitude = ''
    }
  },
)

const isCopied = ref(false)

const copyCoordinates = (e: Event) => {
  e.stopPropagation()
  const text = latLongStr.value
  if (text && text !== t('labels.setLocation')) {
    navigator.clipboard.writeText(text).then(() => {
      isCopied.value = true
      if (copyTooltipTimer) clearTimeout(copyTooltipTimer)
      copyTooltipTimer = setTimeout(() => {
        isCopied.value = false
      }, 2000)
    })
  }
}

const openEditor = (e: Event) => {
  e.stopPropagation()
  if (!readonly.value) {
    isExpanded.value = true
  }
}

const handleKeyDown = (e: KeyboardEvent) => {
  // Allow copy shortcuts to pass through
  if ((e.metaKey || e.ctrlKey) && e.key === 'c') {
    return
  }

  if (e.key === 'Escape' && isExpanded.value) {
    e.preventDefault()
    e.stopImmediatePropagation()
    isExpanded.value = false
  }

  if (e.key === 'Enter') {
    e.preventDefault()
    if (readonly.value) {
      return
    }
    isExpanded.value = !isExpanded.value
  }
}

// --- Map lifecycle: init when overlay opens, destroy when it closes ---
watch(isExpanded, async (expanded) => {
  if (expanded) {
    await nextTick()
    // Leaflet needs the container to be fully rendered and sized
    setTimeout(() => {
      initMap()
      mapInstanceRef.value?.invalidateSize()
      searchInputRef.value?.focus()
    }, 150)
  } else {
    destroyMap()
    resetCitySearch()
  }
})

// --- Bidirectional sync: input fields -> map (debounced) ---
watch(
  () => [formState.latitude, formState.longitude],
  () => {
    syncMapFromInputs()
  },
)

// --- Cleanup on unmount ---
onBeforeUnmount(() => {
  destroyMap()
  searchAbortController?.abort()
  if (searchBlurTimer) clearTimeout(searchBlurTimer)
  if (copyTooltipTimer) clearTimeout(copyTooltipTimer)
})
</script>

<template>
  <div tabindex="0" class="focus:outline-none focus-visible:outline-none" @paste="handlePaste" @keydown="handleKeyDown">
    <NcDropdown v-model:visible="isExpanded" :disabled="readonly" overlay-class-name="nc-geodata-overlay-dropdown">
      <div
        v-if="!isLocationSet"
        :class="{
          '!justify-start !ml-0 ': isExpandedForm || isForm,
          'mt-0.5': isForm && !isPublic,
          '!-mt-0.25': isForm && isPublic,
        }"
        class="w-full flex justify-center max-w-64 mx-auto"
      >
        <NcButton
          v-if="(activeCell && !readonly) || isForm || isEditColumn"
          size="xsmall"
          type="secondary"
          data-testid="nc-geo-data-set-location-button"
        >
          <div class="flex items-center px-2 gap-2">
            <GeneralIcon class="text-nc-content-gray-muted h-3.5 w-3.5" icon="ncMapPin" />
            <span class="text-tiny">
              {{ latLongStr }}
            </span>
          </div>
        </NcButton>
      </div>

      <div
        v-else
        data-testid="nc-geo-data-lat-long-set"
        tabindex="1"
        :class="{
          '!py-1': !isForm,
          'pt-1': isForm && !isPublic,
        }"
        class="nc-cell-field h-full w-full flex items-center focus-visible:!outline-none focus:!outline-none whitespace-nowrap truncate"
      >
        <!-- Expanded form: selectable text with copy + edit buttons -->
        <template v-if="isExpandedForm">
          <span class="nc-geodata-selectable-text" @click.stop>{{ latLongStr }}</span>
          <div v-if="!isLinkRecordDropdown" class="nc-geodata-action-icons" @click.stop>
            <NcTooltip>
              <template #title>{{ isCopied ? $t('general.copied') : $t('general.copy') }}</template>
              <GeneralIcon
                :icon="isCopied ? 'check' : 'copy'"
                class="nc-geodata-action-icon"
                :class="{ '!text-green-600': isCopied }"
                :aria-label="isCopied ? $t('general.copied') : $t('general.copy')"
                role="button"
                tabindex="0"
                @click="copyCoordinates"
                @keydown.enter="copyCoordinates"
              />
            </NcTooltip>
            <NcTooltip v-if="!readonly">
              <template #title>{{ $t('general.edit') }}</template>
              <GeneralIcon
                icon="ncEdit"
                class="nc-geodata-action-icon"
                :aria-label="$t('general.edit')"
                role="button"
                tabindex="0"
                @click="openEditor"
                @keydown.enter="openEditor"
              />
            </NcTooltip>
          </div>
        </template>
        <!-- Grid view: click anywhere to open editor (existing behavior) -->
        <template v-else>
          {{ latLongStr }}
        </template>
      </div>
      <template #overlay>
        <div class="nc-geodata-picker-overlay" @click.stop @paste="handlePaste">
          <a-form :model="formState" class="nc-geodata-form" @finish="handleFinish">
            <!-- Modal content area -->
            <div class="nc-geodata-content">
              <!-- City search -->
              <div v-if="!readonly" class="nc-geodata-city-search">
                <label class="nc-geodata-input-label" :for="identifier.citySearch">{{ $t('labels.city') }}</label>
                <div class="nc-geodata-city-search-box">
                  <GeneralIcon icon="search" class="nc-geodata-search-icon" />
                  <input
                    :id="identifier.citySearch"
                    ref="searchInputRef"
                    v-model="searchQuery"
                    data-testid="nc-geo-data-city-search"
                    type="text"
                    class="nc-geodata-search-input"
                    :placeholder="$t('labels.searchForCity')"
                    autocomplete="off"
                    role="combobox"
                    :aria-expanded="showSearchResults"
                    aria-autocomplete="list"
                    aria-controls="nc-geo-search-results"
                    :aria-activedescendant="
                      highlightedIndex >= 0 ? `nc-geo-search-option-${highlightedIndex}` : undefined
                    "
                    @keydown="onSearchKeydown"
                    @focus="showSearchResults = searchResults.length > 0"
                    @blur="onSearchBlur"
                    @keydown.stop
                    @mousedown.stop
                  />
                  <GeneralIcon v-if="isSearching" icon="loading" class="nc-geodata-search-spinner animate-spin" />
                </div>
                <div
                  v-if="showSearchResults"
                  id="nc-geo-search-results"
                  role="listbox"
                  class="nc-geodata-search-results"
                >
                  <div
                    v-for="(result, index) in searchResults"
                    :id="`nc-geo-search-option-${index}`"
                    :key="result.geoname_id"
                    role="option"
                    class="nc-geodata-search-result-item"
                    :class="{ 'nc-geodata-search-result-item--active': index === highlightedIndex }"
                    :aria-selected="index === highlightedIndex"
                    @mousedown.prevent="selectSearchResult(result)"
                    @mouseenter="highlightedIndex = index"
                  >
                    <GeneralIcon icon="ncMapPin" class="nc-geodata-result-icon" />
                    <div class="nc-geodata-result-body">
                      <span class="nc-geodata-result-name">{{ result.name }}</span>
                      <span v-if="result.cou_name_en || result.population" class="nc-geodata-result-meta">
                        <template v-if="result.cou_name_en">{{ result.cou_name_en }}</template>
                        <template v-if="result.cou_name_en && result.population"> · </template>
                        <template v-if="result.population">{{ formatPopulation(result.population) }}</template>
                      </span>
                    </div>
                  </div>
                  <div v-if="!isSearching && !searchResults.length" class="nc-geodata-search-empty">
                    {{ $t('labels.noCitiesFound') }}
                  </div>
                </div>
              </div>

              <!-- Coordinates section -->
              <div class="nc-geodata-section-label">{{ $t('labels.coordinates') }}</div>
              <div class="nc-geodata-coordinates-grid">
                <div class="nc-geodata-input-group">
                  <label :for="identifier.latitude" class="nc-geodata-input-label">{{ $t('labels.latitude') }}</label>
                  <a-input
                    :id="identifier.latitude"
                    v-model:value="formState.latitude"
                    data-testid="nc-geo-data-latitude"
                    type="number"
                    step="0.0000000001"
                    class="nc-geodata-input-field"
                    :placeholder="t('labels.enterLatitude')"
                    :min="-90"
                    :disabled="readonly"
                    required
                    :max="90"
                    :status="isLatitudeInvalid ? 'error' : ''"
                    @blur="handleBlur"
                    @keydown.stop
                    @selectstart.capture.stop
                    @mousedown.stop
                  />
                  <span v-if="isLatitudeInvalid" class="nc-geodata-error-text">{{ t('msg.error.latitudeRange') }}</span>
                </div>

                <div class="nc-geodata-input-group">
                  <label :for="identifier.longitude" class="nc-geodata-input-label">{{ $t('labels.longitude') }}</label>
                  <a-input
                    :id="identifier.longitude"
                    v-model:value="formState.longitude"
                    data-testid="nc-geo-data-longitude"
                    type="number"
                    step="0.0000000001"
                    class="nc-geodata-input-field"
                    :placeholder="t('labels.enterLongitude')"
                    required
                    :min="-180"
                    :disabled="readonly"
                    :max="180"
                    :status="isLongitudeInvalid ? 'error' : ''"
                    @blur="handleBlur"
                    @keydown.stop
                    @selectstart.capture.stop
                    @mousedown.stop
                  />
                  <span v-if="isLongitudeInvalid" class="nc-geodata-error-text">{{ t('msg.error.longitudeRange') }}</span>
                </div>
              </div>

              <!-- Map with locate control -->
              <div class="nc-geodata-map-wrapper">
                <div
                  ref="mapContainerRef"
                  data-testid="nc-geo-data-map-picker"
                  class="nc-geodata-map-picker"
                  role="application"
                  :aria-label="$t('labels.mapPicker')"
                />

                <!-- Current location button -->
                <div v-if="!readonly" class="nc-geodata-locate-wrapper">
                  <NcTooltip placement="bottom">
                    <template #title>{{ $t('labels.currentLocation') }}</template>
                    <button
                      class="nc-geodata-locate-btn"
                      :class="{ 'nc-geodata-locate-btn--loading': isLoading }"
                      :disabled="isLoading"
                      :aria-label="$t('labels.currentLocation')"
                      type="button"
                      @click.stop.prevent="onClickSetCurrentLocation"
                    >
                      <GeneralIcon v-if="!isLoading" icon="currentLocation" class="h-4 w-4" />
                      <GeneralIcon v-else icon="loading" class="h-4 w-4 animate-spin" />
                    </button>
                  </NcTooltip>
                </div>
              </div>

              <!-- Info hint -->
              <div v-if="!readonly" class="nc-geodata-info-hint">
                <GeneralIcon icon="info" class="h-3.5 w-3.5 flex-shrink-0" />
                <span>{{ $t('labels.clickMapToSetLocation') }}</span>
              </div>
            </div>

            <!-- Footer -->
            <div class="nc-geodata-footer">
              <div class="nc-geodata-footer-left">
                <template v-if="vModel">
                  <NcTooltip>
                    <template #title>
                      <div class="flex items-center gap-1">
                        {{ $t('activity.map.googleMaps') }}
                        <GeneralIcon icon="ncExternalLink" class="h-3 w-3" />
                      </div>
                    </template>
                    <NcButton type="secondary" size="small" class="!px-2" @click="openInGoogleMaps">
                      <GeneralIcon icon="ncLogoGoogleMapColored" class="h-4 w-4" />
                    </NcButton>
                  </NcTooltip>

                  <NcTooltip>
                    <template #title>
                      <div class="flex items-center gap-1">
                        {{ $t('activity.map.osm') }}
                        <GeneralIcon icon="ncExternalLink" class="h-3 w-3" />
                      </div>
                    </template>
                    <NcButton type="secondary" size="small" class="!px-2" @click="openInOSM">
                      <GeneralIcon icon="ncLogoOpenStreetMapColored" class="h-4 w-4" />
                    </NcButton>
                  </NcTooltip>
                </template>
              </div>

              <div class="nc-geodata-footer-right">
                <NcButton
                  v-if="isLocationSet"
                  type="secondary"
                  size="small"
                  class="!text-red-500 !hover:bg-red-50"
                  data-testid="nc-geo-data-clear"
                  @click="clearValue"
                >
                  {{ $t('general.clear') }}
                </NcButton>
                <NcButton type="secondary" size="small" @click="clear">
                  {{ $t('general.cancel') }}
                </NcButton>

                <NcButton html-type="submit" size="small" data-testid="nc-geo-data-save">
                  {{ $t('general.save') }}
                </NcButton>
              </div>
            </div>
          </a-form>
        </div>
      </template>
    </NcDropdown>
  </div>
</template>

<style scoped lang="scss">
/* Selectable coordinate text in expanded form */
.nc-geodata-selectable-text {
  user-select: text;
  cursor: text;
  flex: 1;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.nc-geodata-action-icons {
  @apply flex items-center gap-2 ml-2 flex-shrink-0;
}

.nc-geodata-action-icon {
  @apply w-4 h-4 text-nc-content-gray-muted cursor-pointer;
  transition: color 0.15s;

  &:hover {
    @apply text-nc-content-gray;
  }
}

/* Overlay modal structure */
.nc-geodata-picker-overlay {
  @apply bg-nc-bg-default rounded-xl overflow-hidden flex flex-col;
  width: 540px;
  max-width: 95vw;
  max-height: 85vh;
}

.nc-geodata-form {
  @apply flex flex-col h-full;
}

.nc-geodata-content {
  @apply flex flex-col gap-4 px-5 py-4 overflow-y-auto;
  flex: 1;
}

.nc-geodata-section-label {
  @apply text-nc-content-gray-subtle text-xs font-semibold uppercase tracking-wide mb-1;
}

/* City search */
.nc-geodata-city-search {
  @apply relative flex flex-col gap-1.5;
}

.nc-geodata-city-search-box {
  @apply flex items-center rounded-lg border-1 border-nc-border-gray-medium bg-nc-bg-default;
  padding: 0 12px;
  height: 36px;
  transition: border-color 0.15s, box-shadow 0.15s;

  &:focus-within {
    @apply border-nc-border-brand;
    box-shadow: 0 0 0 2px rgba(51, 102, 255, 0.12);
  }
}

.nc-geodata-search-icon {
  @apply text-nc-content-gray-muted w-4 h-4 flex-shrink-0;
}

.nc-geodata-search-spinner {
  @apply text-nc-content-gray-muted w-3.5 h-3.5 flex-shrink-0;
}

.nc-geodata-search-input {
  @apply flex-1 border-none outline-none text-nc-content-gray bg-transparent min-w-0;
  font-size: 13px;
  padding: 0 8px;

  &::placeholder {
    @apply text-nc-content-gray-muted;
  }
}

.nc-geodata-search-results {
  @apply bg-nc-bg-default rounded-lg border-1 border-nc-border-gray-medium;
  max-height: 220px;
  overflow-y: auto;
}

.nc-geodata-search-result-item {
  @apply flex items-start gap-2 px-3 py-2 cursor-pointer;
  transition: background 0.15s;

  &:hover,
  &--active {
    @apply bg-nc-bg-gray-light;
  }

  &:first-child {
    border-radius: 8px 8px 0 0;
  }

  &:last-child {
    border-radius: 0 0 8px 8px;
  }

  &:only-child {
    border-radius: 8px;
  }
}

.nc-geodata-result-icon {
  @apply text-nc-content-gray-muted w-3.5 h-3.5 flex-shrink-0 mt-0.5;
}

.nc-geodata-result-body {
  @apply flex flex-col min-w-0 gap-0.5;
}

.nc-geodata-result-name {
  @apply text-nc-content-gray text-sm leading-[1.3] truncate;
}

.nc-geodata-result-meta {
  @apply text-nc-content-gray-muted text-xs leading-[1.3] truncate;
}

.nc-geodata-search-empty {
  @apply px-3 py-2.5 text-nc-content-gray-muted text-xs;
}

/* Two-column coordinates grid */
.nc-geodata-coordinates-grid {
  @apply grid grid-cols-2 gap-4;
}

.nc-geodata-input-group {
  @apply flex flex-col gap-1.5;
}

.nc-geodata-input-label {
  @apply text-nc-content-gray text-small font-medium;
}

.nc-geodata-input-field {
  @apply !rounded-lg;
}

:deep(.nc-geodata-input-field input) {
  @apply !text-sm;
}

.nc-geodata-error-text {
  @apply text-nc-content-red-dark text-xs;
}

/* Map wrapper (relative container for overlay controls) */
.nc-geodata-map-wrapper {
  @apply relative;
}

/* Interactive map picker */
.nc-geodata-map-picker {
  @apply border-1 border-nc-border-gray-medium rounded-xl overflow-hidden;
  height: 300px;
  z-index: 0;
}

/* Dark mode: invert OSM tiles via CSS filter to preserve detail */
:deep(.nc-geodata-map-picker .leaflet-tile-pane) {
  html.dark & {
    filter: invert(1) hue-rotate(180deg) brightness(0.95) contrast(0.9);
  }
}

/* Wrapper positions the locate button absolutely on the map */
.nc-geodata-locate-wrapper {
  @apply absolute;
  top: 12px;
  right: 12px;
  z-index: 1000;
}

/* Current-location icon button on map — aligned with search bar */
.nc-geodata-locate-btn {
  @apply flex items-center justify-center bg-nc-bg-default rounded-lg cursor-pointer border-none;
  width: 36px;
  height: 36px;
  box-shadow: 0 1px 4px rgba(0, 0, 0, 0.12);
  transition: background 0.15s;
  color: var(--nc-content-gray-subtle);

  &:hover:not(:disabled) {
    @apply bg-nc-bg-gray-light border-nc-border-gray-dark;
    color: var(--nc-content-gray);
  }

  &:disabled {
    @apply cursor-wait opacity-70;
  }

  &--loading {
    color: var(--nc-content-brand);
  }
}

:deep(.nc-geodata-map-picker .leaflet-control-zoom) {
  border: none;
  border-radius: 8px;
  overflow: hidden;
  box-shadow: 0 1px 4px rgba(0, 0, 0, 0.12);

  a {
    @apply bg-nc-bg-default text-nc-content-gray;
    text-decoration: none !important;
    border-bottom-color: var(--nc-border-gray-medium, #e5e7eb) !important;

    &:hover {
      @apply bg-nc-bg-gray-light;
    }
  }
}

:deep(.nc-geodata-map-picker .leaflet-control-attribution) {
  @apply text-[10px] bg-nc-bg-default/80 text-nc-content-gray-muted;

  a {
    @apply text-nc-content-gray-muted;
  }
}

/* Info hint below map */
.nc-geodata-info-hint {
  @apply flex items-center gap-1.5 text-nc-content-gray-muted text-xs -mt-2;
}

/* Footer */
.nc-geodata-footer {
  @apply flex items-center justify-between gap-3 px-5 py-3 border-t-1 border-nc-border-gray-medium bg-nc-bg-gray-extralight;
}

.nc-geodata-footer-left {
  @apply flex gap-2;
}

.nc-geodata-footer-right {
  @apply flex gap-2;
}
</style>

<style lang="scss">
.nc-geodata-overlay-dropdown {
  min-width: 540px !important;
  max-width: 95vw !important;

  .ant-dropdown-content {
    @apply !p-0;
  }
}
</style>
