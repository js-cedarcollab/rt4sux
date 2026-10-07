-- Monitored stops. stop_id equals Metro's GTFS stop_id and public stop number.
-- focus_windows are Pacific local times; the poller only runs (weekdays) inside them,
-- padded by config.poll_padding_min on each side.
alter table public.stops add column if not exists focus_windows jsonb;

insert into public.stops (stop_id, name, direction, role, notes, focus_windows) values
('41255','3rd Ave W & W Cremona St','A','route_start','Timetable stop; route start',null),
('3930','Boston St & Queen Anne Ave N','A',null,'Timetable stop',null),
('2220','3rd Ave & Cedar St','A',null,'Timetable stop',null),
('12910','9th Ave & Jefferson St','A','route_end','Timetable stop',null),
('12880','Jefferson St & 9th Ave','B','route_start','Timetable stop',null),
('1690','3rd Ave & Vine St','B',null,'Timetable stop; spec said 3rd Ave & Cedar St but GTFS names 1690 as Vine St',null),
('4370','Boston St & 1st Ave N','B',null,'Timetable stop',null),
('18220','W Nickerson St & 3rd Ave W','B','route_end','Timetable stop; route end',null),
('41300','3rd Ave W & W McGraw St','A','boarding_am','Morning boarding stop toward downtown. GTFS direction_id 0, stop sequence 5 (a few minutes after the route start).','[{"start":"07:30","end":"09:30"}]'),
('4230','5th Ave N & Republican St','B','boarding_pm','Evening boarding stop at the Gates Foundation offices (nearest to 500 5th Ave N), toward Queen Anne. GTFS direction_id 1.','[{"start":"16:00","end":"18:00"}]')
on conflict (stop_id) do nothing;
