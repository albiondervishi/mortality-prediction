DROP TABLE IF EXISTS dm_cohort CASCADE;
CREATE TABLE dm_cohort AS
with ce as
(
  select icustay_id
    , min(charttime) as intime_hr
    , max(charttime) as outtime_hr
  from chartevents ce
  -- very loose join to admissions to ensure charttime is near patient admission
  inner join admissions adm
    on ce.hadm_id = adm.hadm_id
    and ce.charttime between adm.admittime - interval '1' day and adm.dischtime + interval '1' day
  where itemid in (211,220045)
  group by icustay_id
)
-- tr.rn is the last unit the patient stayed in the hospital
-- we join to tr to check if the last unit the patient stayed in was an icu
, tr as
(
select hadm_id, icustay_id, intime, outtime, curr_careunit
, ROW_NUMBER() over (partition by hadm_id order by intime desc) as rn
from mimiciii.transfers
where outtime is not null
)
, ds as
(
  select distinct hadm_id
  from noteevents
  where category = 'Discharge summary'
)
-- alcohol- use dependence related ICD-9
-- (291.X, 291.XX, 303.XX,  357.5, 425.5, 535.3X, 571.2, and 571.3)
-- ** paper says 305.XX but I'm sure it should be 305.0X
, icd_alc as
(
  select distinct hadm_id
  from diagnoses_icd
  where
     icd9_code like '291%'
     -- this length() is needed, e.g. 3051 is tobacco use *not* alcohol
  or (icd9_code like '303%' and length(icd9_code)=5)
  or icd9_code like '3050%'
  or icd9_code = '3575'
  or icd9_code = '4255'
  or icd9_code like '5353%'
  or icd9_code = '5712'
  or icd9_code = '5713'
)
, icd_aki as
(
  select distinct hadm_id
  from diagnoses_icd
  where
     icd9_code = '5849'
)
, icd_sah as
(
  select distinct hadm_id
  from diagnoses_icd
  where
     icd9_code = '430'
     -- technically this is subdural and extradural too, not just SAH
  or icd9_code like '852%'
)
select
    ie.subject_id, ie.hadm_id, ie.icustay_id
  , ce.intime_hr as intime
  , ce.outtime_hr as outtime
  , round((cast(adm.admittime as date) - cast(pat.dob as date)) / 365.242, 4) as age
  , pat.gender
  , adm.ethnicity

  -- outcomes
  -- 48 post ICU admission -- TODO: check ~1700 pts die after other exclusions
  , case
      when adm.deathtime is not null and adm.deathtime <= ce.intime_hr + interval '48' hour
        then 1
      else 0
    end as death_48hr_post_icu_admit
  -- in ICU
	, case
      when adm.hospital_expire_flag = 1 and tr.outtime is not null
        then 1
      else 0
    end as death_icu
  -- in hospital
  , adm.HOSPITAL_EXPIRE_FLAG
  -- 30-day post ICU admission
  , case
      -- died in hospital
      when adm.deathtime is not null and adm.deathtime <= ce.intime_hr + interval '30' day
        then 1
      -- died outside of hospital or during a later readmission to hospital
      when pat.dod is not null and pat.dod <= ce.intime_hr + interval '30' day
        then 1
      else 0
    end as death_30dy_post_icu_admit
  -- 30-day post ICU discharge
  , case
      -- died in hospital
      when adm.deathtime is not null and adm.deathtime <= ce.outtime_hr + interval '30' day
        then 1
      -- died outside of hospital or during a later readmission to hospital
      when pat.dod is not null and pat.dod <= ce.outtime_hr + interval '30' day
        then 1
      else 0
    end as death_30dy_post_icu_disch
  -- 30-day post hospital discharge
  , case
      -- died in hospital
      when adm.deathtime is not null and adm.deathtime <= adm.dischtime + interval '30' day
        then 1
      -- died outside of hospital or during a later readmission to hospital
      when pat.dod is not null and pat.dod <= adm.dischtime + interval '30' day
        then 1
      else 0
    end as death_30dy_post_hos_disch
  -- 6-month post hospital discharge
  , case
      -- died in hospital
      when adm.deathtime is not null and adm.deathtime <= adm.dischtime + interval '6' month
        then 1
      -- died outside of hospital or during a later readmission to hospital
      when pat.dod is not null and pat.dod <= adm.dischtime + interval '6' month
        then 1
      else 0
    end as death_6mo_post_hos_disch
  -- 1-year post hospital discharge
  , case
      -- died in hospital
      when adm.deathtime is not null and adm.deathtime <= adm.dischtime + interval '1' year
        then 1
      -- died outside of hospital or during a later readmission to hospital
      when pat.dod is not null and pat.dod <= adm.dischtime + interval '1' year
        then 1
      else 0
    end as death_1yr_post_hos_disch
  -- 2-year post hospital discharge
  , case
      -- died in hospital
      when adm.deathtime is not null and adm.deathtime <= adm.dischtime + interval '1' year
        then 1
      -- died outside of hospital or during a later readmission to hospital
      when pat.dod is not null and pat.dod <= adm.dischtime + interval '1' year
        then 1
      else 0
    end as death_2yr_post_hos_disch

  -- this isn't used in any study ... but is the more usual definition of 30-day mort, centered on *hospital admission*
  , case when pat.dod <= adm.admittime + interval '30' day then 1 else 0 end
      as death_30dy_post_hos_admit

  -- other outcomes
  , ie.los as icu_los
  , extract(epoch from (adm.dischtime - adm.admittime))/60.0/60.0/24.0 as hosp_los
  , ceil(extract(epoch from (adm.deathtime - ce.intime_hr))/60.0/60.0) as deathtime_hours

  -- exclusions
  , case when round((cast(adm.admittime as date) - cast(pat.dob as date)) / 365.242, 4) <= 15
      then 1
    else 0 end as exclusion_over_15
  , case when round((cast(adm.admittime as date) - cast(pat.dob as date)) / 365.242, 4) <= 16
      then 1
    else 0 end as exclusion_over_16
  , case when round((cast(adm.admittime as date) - cast(pat.dob as date)) / 365.242, 4) <= 18
      then 1
    else 0 end as exclusion_over_18
  , case when adm.HAS_CHARTEVENTS_DATA = 0 then 1
         when ie.intime is null then 1
         when ie.outtime is null then 1
         when ce.intime_hr is null then 1
         when ce.outtime_hr is null then 1
      else 0 end as exclusion_valid_data

  -- length of stay flags
  , case
      when (ce.outtime_hr-ce.intime_hr) < interval '4' hour then 1
    else 0 end as exclusion_stay_lt_4hr
  , case
      when (ce.outtime_hr-ce.intime_hr) < interval '17' hour then 1
    else 0 end as exclusion_stay_lt_17hr
  , case
      when (ce.outtime_hr-ce.intime_hr) < interval '24' hour then 1
    else 0 end as exclusion_stay_lt_24hr
  , case
      when (ce.outtime_hr-ce.intime_hr) < interval '48' hour then 1
    else 0 end as exclusion_stay_lt_48hr
  , case
      when (ce.outtime_hr-ce.intime_hr) > interval '500' hour then 1
    else 0 end as exclusion_stay_gt_500hr

  -- organ donor accounts
  , case when (
         (lower(diagnosis) like '%organ donor%' and deathtime is not null)
      or (lower(diagnosis) like '%donor account%' and deathtime is not null)
    ) then 1 else 0 end as exclusion_organ_donor

  -- regardless of the individual exclusions, we have some basic exclusions
  -- these are satisfied by all studies, and reduce the data size
  , case when round((cast(adm.admittime as date) - cast(pat.dob as date)) / 365.242, 4) <= 15 then 1
         when adm.HAS_CHARTEVENTS_DATA = 0 then 1
         when ie.intime is null then 1
         when ie.outtime is null then 1
         when ce.intime_hr is null then 1
         when ce.outtime_hr is null then 1
         when (ce.outtime_hr-ce.intime_hr) <= interval '4' hour then 1
         when lower(diagnosis) like '%organ donor%' and deathtime is not null then 1
         when lower(diagnosis) like '%donor account%' and deathtime is not null then 1
      else 0 end
    as excluded

  -- now we have individual study exclusions

  -- calvert2016computational
  -- only alcoholic dependence patients
  , case when icd_alc.hadm_id is null then 1 else 0 end as exclusion_non_alc_icd9
  -- TODO: >1 obs for all features: heart rate, pulse pressure, respiration rate, spo2, systolic blood pressure, temperature, wbc, pH


  -- celi2012database
  , case when icd_aki.hadm_id is null then 1 else 0 end as exclusion_non_aki_icd9
  , case when icd_sah.hadm_id is null then 1 else 0 end as exclusion_non_sah_icd9

  -- ghassemi2014unfolding
  , case when wc.non_stop_words < 100 then 1 else 0 end as exclusion_lt_100_non_stop_words

  -- grnarova2016neural
  -- from paper: "... with only one hospital admission"
  , case when count(ie.hadm_id) OVER (partition by ie.subject_id) > 1 then 1 else 0 end as exclusion_multiple_hadm

  -- harutyunyan2017multitask
  -- "excluded any hospital admission with multiple ICU stays or transfers between different ICU units or wards"
  -- looking at source code, it's count(icustay_id) > 1 for any hadm_id
  , case when count(ie.icustay_id) OVER (partition by ie.hadm_id) > 1 then 1 else 0 end as exclusion_multiple_icustay

  -- lehman2012risk
  -- missing saps-i
  , case when obs.saps_vars > 0 then 0 else 1 end as exclusion_has_saps
  , case when ROW_NUMBER() OVER (partition by ie.hadm_id order by ie.intime) > 1 then 1 else 0 end as exclusion_readmission

  -- luo2016interpretable
  , case when ds.hadm_id is null then 1 else 0 end as exclusion_no_disch_summary
  -- TODO: sapsii
from icustays ie
inner join admissions adm
  on ie.hadm_id = adm.hadm_id
inner join patients pat
  on ie.subject_id = pat.subject_id
left join ce
  on ie.icustay_id = ce.icustay_id
left join tr
	on ie.icustay_id = tr.icustay_id
	and tr.rn = 1
left join icd_alc
  on ie.hadm_id = icd_alc.hadm_id
left join icd_aki
  on ie.hadm_id = icd_aki.hadm_id
left join icd_sah
  on ie.hadm_id = icd_sah.hadm_id
left join dm_word_count wc
  on ie.hadm_id = wc.hadm_id
left join ds
  on ie.hadm_id = ds.hadm_id
left join dm_obs_count obs
  on ie.icustay_id = obs.icustay_id
order by ie.icustay_id;